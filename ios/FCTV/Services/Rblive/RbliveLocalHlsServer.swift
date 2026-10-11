import CryptoKit
import Foundation
import Network

/// Tiny loopback HTTP proxy for HLS: fetches upstream with RB headers, rewrites CSL
/// segments through this proxy (resolving CTU with retries at fetch time), serves MPEG-TS.
///
/// URLs are registered under short opaque ids (`/m3u8?i=…`) because AVPlayer truncates
/// very long query strings (base64 of full CDN URLs).
///
/// Ids are a stable hash of the upstream URL so live playlist reloads keep the same
/// local URI for the same MEDIA-SEQUENCE (AVPlayer errors with
/// "Media Entry URL not match previous playlist" if the URI changes).
final class RbliveLocalHlsServer: @unchecked Sendable {
    static let shared = RbliveLocalHlsServer()

    private var listener: NWListener?
    private(set) var port: UInt16?
    private var headers: [String: String] = [:]
    private var registry: [String: String] = [:]
    private let queue = DispatchQueue(label: "fctv.rblive.local-hls")
    private let lock = NSLock()
    /// Ephemeral + no-cache: live m3u8 must not be served from URLSession disk/memory cache
    /// (stale MEDIA-SEQUENCE → AVPlayer drains the ~45s window and freezes).
    private static let upstreamSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    /// Tear down a zombie listener (common after long background suspension) so the next play rebinds.
    func restart() {
        lock.lock()
        listener?.cancel()
        listener = nil
        port = nil
        registry.removeAll()
        lock.unlock()
        fputs("[hls-local] restart (listener cleared)\n", stderr)
    }

    func ensureRunning(extraHeaders: [String: String]) throws -> URL {
        lock.lock()
        headers = Self.canonical(extraHeaders)
        // Always keep a Referer — CTU CDNs reject bare fetches after a short window.
        if headers["referer"] == nil {
            if let ref = UserDefaults.standard.string(forKey: "fctv.rblive.http_referer")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !ref.isEmpty {
                headers["referer"] = ref
            } else {
                headers["referer"] = "https://www.fctv33.com/"
            }
        }
        if headers["user-agent"] == nil {
            headers["user-agent"] = "rbapp/--dg-77-ios/unknown"
        }
        // Reuse only while the listener is still ready — failed/cancelled refs must rebind.
        if let port, let listener, case .ready = listener.state {
            lock.unlock()
            return URL(string: "http://127.0.0.1:\(port)")!
        }
        if listener != nil {
            listener?.cancel()
            listener = nil
            self.port = nil
        }
        lock.unlock()
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        let sem = DispatchSemaphore(value: 0)
        var boundPort: UInt16?
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port?.rawValue
                sem.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.handle(conn) }
        }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 3)
        guard let p = boundPort else {
            throw RbliveAPIError.streamCryptoFailed("local HLS server bind failed")
        }
        lock.lock()
        port = p
        lock.unlock()
        fputs("[hls-local] listening on 127.0.0.1:\(p)\n", stderr)
        return URL(string: "http://127.0.0.1:\(p)")!
    }

    func playableURL(for upstream: URL, extraHeaders: [String: String]) throws -> URL {
        let base = try ensureRunning(extraHeaders: extraHeaders)
        let id = register(upstream.absoluteString)
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/m3u8"
        c.queryItems = [URLQueryItem(name: "i", value: id)]
        return c.url!
    }

    private func register(_ url: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let digest = Insecure.MD5.hash(data: Data(url.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        // 16 hex chars is enough and keeps proxy URLs short for AVPlayer.
        let short = String(key.prefix(16))
        registry[short] = url
        return short
    }

    private func lookup(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return registry[id]
    }

    private var snapshotHeaders: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return headers
    }

    private var snapshotPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return port ?? 0
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                fputs("[hls-local] recv err \(error)\n", stderr)
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel(); return }
                self.receiveHeader(connection, buffer: buf)
                return
            }
            let headerData = buf.subdata(in: buf.startIndex ..< range.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let first = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                self.respond(connection, status: 405, contentType: "text/plain", body: Data("method".utf8))
                return
            }
            let pathQuery = String(parts[1])
            fputs("[hls-local] GET \(pathQuery.prefix(96))\n", stderr)
            self.serve(pathQuery: pathQuery, connection: connection)
        }
    }

    private func serve(pathQuery: String, connection: NWConnection) {
        guard let comps = URLComponents(string: "http://x\(pathQuery)"),
              let id = comps.queryItems?.first(where: { $0.name == "i" })?.value,
              let upstream = lookup(id),
              let upstreamURL = URL(string: upstream)
        else {
            fputs("[hls-local] bad/missing id in \(pathQuery.prefix(80))\n", stderr)
            respond(connection, status: 400, contentType: "text/plain", body: Data("bad url".utf8))
            return
        }
        let isPlaylist = comps.path.contains("m3u8") || upstream.lowercased().contains(".m3u8")
        let hdrs = snapshotHeaders
        let portSnapshot = snapshotPort
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                if isPlaylist {
                    let (data, _) = try await Self.fetch(url: upstreamURL, headers: hdrs)
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let rewritten = self.rewrite(text, document: upstreamURL, port: portSnapshot)
                    fputs("[hls-local] playlist \(data.count)→\(rewritten.utf8.count) B\n", stderr)
                    try? rewritten.write(toFile: "/tmp/rewritten.m3u8", atomically: true, encoding: .utf8)
                    Self.respondStatic(
                        connection,
                        status: 200,
                        contentType: "application/vnd.apple.mpegurl",
                        body: Data(rewritten.utf8),
                        cacheControl: "no-store"
                    )
                } else {
                    let data = try await Self.fetchSegment(url: upstreamURL, headers: hdrs)
                    fputs("[hls-local] segment \(data.count) B sync=\(data.first == 0x47)\n", stderr)
                    Self.respondStatic(connection, status: 200, contentType: "video/mp2t", body: data)
                }
            } catch {
                fputs("[hls-local] upstream \(error.localizedDescription)\n", stderr)
                Self.respondStatic(connection, status: 502, contentType: "text/plain", body: Data("upstream".utf8))
            }
        }
    }

    /// Keep original (CSL) segment URLs in the registry — resolve CTU with retries at fetch time
    /// (same as Node `proxy/csl.ts`). Pre-resolving a single CTU host at rewrite time dies after ~30–45s.
    private func rewrite(_ text: String, document: URL, port: UInt16) -> String {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        var out: [String] = []
        for line in text.components(separatedBy: CharacterSet.newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                out.append(line)
                continue
            }
            guard let abs = URL(string: trimmed, relativeTo: document)?.absoluteURL
                    ?? URL(string: trimmed)
            else {
                out.append(line)
                continue
            }
            let id = register(abs.absoluteString)
            var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            let isM3U = abs.pathExtension.lowercased() == "m3u8" || abs.absoluteString.contains(".m3u8")
            c.path = isM3U ? "/m3u8" : "/seg.ts"
            c.queryItems = [URLQueryItem(name: "i", value: id)]
            out.append(c.url?.absoluteString ?? abs.absoluteString)
        }
        // HLS parsers require a trailing newline; without it AVPlayer can stall after the window.
        var joined = out.joined(separator: "\n")
        if !joined.hasSuffix("\n") { joined += "\n" }
        return joined
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, body: Data) {
        Self.respondStatic(connection, status: status, contentType: contentType, body: body)
    }

    private static func respondStatic(
        _ connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        cacheControl: String? = nil
    ) {
        let reason = status == 200 ? "OK" : "ERR"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        if let cacheControl {
            header += "Cache-Control: \(cacheControl)\r\n"
        }
        header += "Access-Control-Allow-Origin: *\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Fetch a media segment — CSL placeholders get multi-host CTU retries + Referer.
    private static func fetchSegment(url: URL, headers: [String: String]) async throws -> Data {
        if RbliveCslResolver.isCslSegmentURL(url.absoluteString) {
            return try await fetchCslSegment(url.absoluteString, headers: headers)
        }
        let (data, _) = try await fetch(url: url, headers: headers)
        return data
    }

    private static func fetchCslSegment(_ segmentURL: String, headers: [String: String]) async throws -> Data {
        let cfg = RbliveCslResolver.currentConfig()
        let items = RbliveCslResolver.resolveCtuURLs(segmentURL: segmentURL, config: cfg)
        guard !items.isEmpty else {
            throw RbliveAPIError.streamCryptoFailed("csl ctu list empty")
        }
        let attempts = min(items.count, max(1, cfg.maxRetryTimes + 1))
        var lastError: Error?
        let referer = headers["referer"] ?? "https://www.fctv33.com/"
        let origin = referer.hasSuffix("/") ? String(referer.dropLast()) : referer
        for index in 0 ..< attempts {
            let item = items[index]
            let timeout = max(cfg.minFetchTimeout, item.timeoutSec)
            guard let ctuURL = URL(string: item.url) else { continue }
            do {
                var req = URLRequest(url: ctuURL, timeoutInterval: timeout)
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.setValue(referer, forHTTPHeaderField: "Referer")
                req.setValue(origin, forHTTPHeaderField: "Origin")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                let (data, resp) = try await upstreamSession.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if (200 ... 299).contains(status), !data.isEmpty {
                    return data
                }
                lastError = RbliveAPIError.http(status, "ctu \(item.ccode)")
                fputs("[hls-local] ctu fail \(item.ccode) status=\(status)\n", stderr)
            } catch {
                lastError = error
                fputs("[hls-local] ctu err \(item.ccode): \(error.localizedDescription)\n", stderr)
            }
        }
        throw lastError ?? RbliveAPIError.streamCryptoFailed("csl failed")
    }

    private static func fetch(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "Referer") == nil, let ref = headers["referer"] {
            req.setValue(ref, forHTTPHeaderField: "Referer")
        }
        let (data, resp) = try await upstreamSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw RbliveAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, nil)
        }
        return (data, http)
    }

    private static func canonical(_ h: [String: String]) -> [String: String] {
        var m: [String: String] = [:]
        for (k, v) in h { m[k.lowercased()] = v }
        return m
    }
}

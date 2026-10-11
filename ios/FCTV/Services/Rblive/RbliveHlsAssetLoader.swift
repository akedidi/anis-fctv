import AVFoundation
import Foundation

/// Intercepts HLS playlist and media requests under the `rblivehls` scheme: fetches the real HTTPS URL,
/// applies `actionSouInject` when enabled (segment `_sou`), rewrites nested `.m3u8` to stay on the proxy.
///
/// Mirrors Android `HlsInjectFetcher` + playlist rewriting so `AVPlayer` never hits raw `_sou` URLs without decoding.
///
/// Uses a dedicated queue + semaphore URLSession (not Swift `Task`/`await`) so loads complete under
/// CLI RunLoop pumps and under `AVAssetResourceLoader` background callbacks.
final class RbliveHlsAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let baseHTTPHeaders: [String: String]
    private let rbUserAgent: String
    private let urlSession: URLSession
    private let workQueue = DispatchQueue(label: "fctv.rblive.hls.loader")

    init(baseHTTPHeaders: [String: String], rbUserAgent: String) {
        self.baseHTTPHeaders = Self.canonicalHeaderKeys(baseHTTPHeaders)
        self.rbUserAgent = rbUserAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 180
        self.urlSession = URLSession(configuration: cfg)
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if ProcessInfo.processInfo.environment["FCTV_DEBUG_HLS"] == "1" {
            fputs("[hls] shouldWait \(loadingRequest.request.url?.absoluteString.prefix(120) ?? "?")\n", stderr)
        }
        workQueue.async { [weak self] in
            self?.handleSync(loadingRequest)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {}

    private func handleSync(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let debug = ProcessInfo.processInfo.environment["FCTV_DEBUG_HLS"] == "1"
        guard let proxyURL = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: Self.err("missing url"))
            return
        }
        guard let targetString = RbliveHlsProxyURL.underlyingURLString(from: proxyURL),
              let documentURL = URL(string: targetString) else {
            if debug { fputs("[hls] bad proxy decode \(proxyURL.absoluteString.prefix(160))\n", stderr) }
            loadingRequest.finishLoading(with: Self.err("bad proxy url"))
            return
        }
        if debug { fputs("[hls] target=\(targetString.prefix(120))\n", stderr) }

        let (fetchURLString, headers) = Self.resolveFetchURLAndHeaders(
            target: targetString,
            baseHeaders: baseHTTPHeaders,
            rbUserAgent: rbUserAgent
        )
        if debug { fputs("[hls] fetch=\(fetchURLString.prefix(120))\n", stderr) }

        // Do NOT forward AVPlayer `Range` probes to origin: a `bytes=0-1` probe would make us
        // treat a 2-byte body as the full HLS playlist (`contentLength=2`) and stall forever.

        let fetchResult: (Data, HTTPURLResponse)
        do {
            fetchResult = try Self.fetchBytes(
                urlString: fetchURLString,
                headers: headers,
                session: urlSession,
                debug: debug
            )
        } catch {
            if debug { fputs("[hls] fetch error \(error.localizedDescription)\n", stderr) }
            loadingRequest.finishLoading(with: error as NSError)
            return
        }
        let (data, http) = fetchResult

        let mime = http.mimeType?.lowercased() ?? ""
        let text = String(data: data, encoding: .utf8) ?? ""
        let looksLikeHLS = mime.contains("mpegurl") || mime.contains("m3u8") || text.hasPrefix("#EXTM3U")
        let payload: Data
        if looksLikeHLS {
            let rewritten = Self.rewritePlaylistText(text, documentHTTPS: documentURL)
            payload = Data(rewritten.utf8)
            loadingRequest.contentInformationRequest?.contentType = "application/vnd.apple.mpegurl"
            loadingRequest.contentInformationRequest?.contentLength = Int64(payload.count)
            // Playlists: no byte-range — always return the full body below.
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        } else {
            payload = data
            // CSL CTU often serves MPEG-TS under .json / .woff2 / .ps paths — force video/mp2t.
            if payload.count >= 1, payload[0] == 0x47 {
                loadingRequest.contentInformationRequest?.contentType = "video/mp2t"
            } else if mime.contains("mp2t") || mime.contains("octet-stream") || targetString.lowercased().contains(".ts") {
                loadingRequest.contentInformationRequest?.contentType = mime.isEmpty ? "video/mp2t" : mime
            } else if !mime.isEmpty {
                loadingRequest.contentInformationRequest?.contentType = mime
            } else {
                loadingRequest.contentInformationRequest?.contentType = "video/mp2t"
            }
            loadingRequest.contentInformationRequest?.contentLength = Int64(payload.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
        }
        if ProcessInfo.processInfo.environment["FCTV_DEBUG_HLS"] == "1" {
            fputs("[hls] served \(targetString.prefix(100)) bytes=\(payload.count) hls=\(looksLikeHLS)\n", stderr)
        }
        if let dataReq = loadingRequest.dataRequest {
            if looksLikeHLS || dataReq.requestsAllDataToEndOfResource || dataReq.requestedLength < 0 {
                // Full body — AVPlayer's 2-byte Range probe must not truncate the playlist.
                dataReq.respond(with: payload)
            } else {
                let offset = Int(dataReq.requestedOffset)
                if offset < payload.count {
                    let end = min(payload.count, offset + dataReq.requestedLength)
                    if offset < end {
                        dataReq.respond(with: payload.subdata(in: offset ..< end))
                    }
                }
            }
        }
        loadingRequest.finishLoading()
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "RbliveHlsAssetLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Fetch playlist/segment bytes. CSL placeholders (`_ctump`) are rewritten to signed CTU hosts.
    private static func fetchBytes(
        urlString: String,
        headers: [String: String],
        session: URLSession,
        debug: Bool
    ) throws -> (Data, HTTPURLResponse) {
        let candidates: [String]
        if RbliveCslResolver.isCslSegmentURL(urlString) {
            let cfg = RbliveCslResolver.currentConfig()
            let ctus = RbliveCslResolver.resolveCtuURLs(segmentURL: urlString, config: cfg)
            if debug {
                fputs("[hls] CSL candidates=\(ctus.count) salt=\(cfg.salt)\n", stderr)
            }
            if ctus.isEmpty {
                candidates = [urlString]
            } else {
                let limit = min(ctus.count, max(1, cfg.maxRetryTimes + 1))
                candidates = Array(ctus.prefix(limit).map(\.url))
            }
        } else {
            candidates = [urlString]
        }

        var lastError: Error = err("no candidates")
        for (idx, candidate) in candidates.enumerated() {
            guard let fetchURL = URL(string: candidate) else { continue }
            var req = URLRequest(url: fetchURL)
            req.httpShouldHandleCookies = true
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            let sem = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultResp: URLResponse?
            var resultErr: Error?
            session.dataTask(with: req) { data, resp, err in
                resultData = data
                resultResp = resp
                resultErr = err
                sem.signal()
            }.resume()
            let waitResult = sem.wait(timeout: .now() + 40)
            if waitResult == .timedOut {
                lastError = err("url session timeout")
                if debug { fputs("[hls] timeout candidate[\(idx)]\n", stderr) }
                continue
            }
            if let resultErr {
                lastError = resultErr
                continue
            }
            guard let data = resultData, let http = resultResp as? HTTPURLResponse else {
                lastError = err("not http")
                continue
            }
            guard (200 ... 299).contains(http.statusCode), !data.isEmpty else {
                lastError = err("http \(http.statusCode)")
                if debug { fputs("[hls] HTTP \(http.statusCode) candidate[\(idx)]\n", stderr) }
                continue
            }
            if debug {
                fputs("[hls] OK candidate[\(idx)] bytes=\(data.count) \(candidate.prefix(100))\n", stderr)
            }
            return (data, http)
        }
        throw lastError
    }

    private static func canonicalHeaderKeys(_ h: [String: String]) -> [String: String] {
        var m: [String: String] = [:]
        for (k, v) in h { m[k.lowercased()] = v }
        return m
    }

    private static func resolveFetchURLAndHeaders(
        target: String,
        baseHeaders: [String: String],
        rbUserAgent: String
    ) -> (String, [String: String]) {
        // Avoid `DispatchQueue.main.sync` here: when the resource-loader delegate queue or the
        // CLI probe holds the main RunLoop, syncing to main deadlocks and AVPlayer never loads.
        if !stinjLikelyEnabled(), !target.contains("_sou") {
            return (target, baseHeaders)
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                resolveFetchURLAndHeadersOnMainActor(
                    target: target,
                    baseHeaders: baseHeaders,
                    rbUserAgent: rbUserAgent
                )
            }
        }
        var out: (String, [String: String]) = (target, baseHeaders)
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            out = MainActor.assumeIsolated {
                resolveFetchURLAndHeadersOnMainActor(
                    target: target,
                    baseHeaders: baseHeaders,
                    rbUserAgent: rbUserAgent
                )
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    private static func stinjLikelyEnabled() -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--uitesting-stinj-enabled") { return true }
        let e = ProcessInfo.processInfo.environment["FCTV_STINJ_ENABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return e == "1" || e == "true" || e == "yes"
    }

    @MainActor
    private static func resolveFetchURLAndHeadersOnMainActor(
        target: String,
        baseHeaders: [String: String],
        rbUserAgent: String
    ) -> (String, [String: String]) {
        if RbliveHlsInjectEngine.injectEnabled,
           let r = RbliveHlsInjectEngine.actionSouInject(
               type: .segmentSouInject,
               url: target,
               srcHeaders: [:],
               rbUserAgent: rbUserAgent
           ) {
            return (r.url, canonicalHeaderKeys(r.headers))
        }
        if let sou = RbliveHlsInjectEngine.souUrl(from: target) {
            return (sou, baseHeaders)
        }
        return (target, baseHeaders)
    }

    fileprivate static func resolveAbsolute(_ relOrAbs: String, document: URL) -> URL? {
        let t = relOrAbs.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
            return URL(string: t)
        }
        return URL(string: t, relativeTo: document)?.absoluteURL
    }

    static func rewritePlaylistText(_ text: String, documentHTTPS: URL) -> String {
        let cleaned: String
        if text.hasPrefix("\u{FEFF}") {
            cleaned = String(text.dropFirst())
        } else {
            cleaned = text
        }
        let cfg = RbliveCslResolver.currentConfig()
        let rawLines = cleaned.components(separatedBy: CharacterSet.newlines)
        var out: [String] = []
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                out.append(rewriteTaggedLine(line, document: documentHTTPS))
                continue
            }
            guard let abs = resolveAbsolute(trimmed, document: documentHTTPS),
                  let sch = abs.scheme?.lowercased(), sch == "http" || sch == "https"
            else {
                out.append(line)
                continue
            }
            // CSL → signed CTU, then always wrap as `rblivehls://…/segment.ts` so AVPlayer
            // accepts the URI (CTU paths use decoy extensions .ps/.webm/.json that AVPlayer
            // and ffmpeg otherwise reject).
            if RbliveCslResolver.isCslSegmentURL(abs.absoluteString),
               let ctu = RbliveCslResolver.resolveCtuURLs(segmentURL: abs.absoluteString, config: cfg).first,
               let ctuURL = URL(string: ctu.url) {
                out.append(RbliveHlsProxyURL.playlistLine(for: ctuURL))
            } else {
                out.append(RbliveHlsProxyURL.playlistLine(for: abs))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func rewriteTaggedLine(_ line: String, document: URL) -> String {
        guard line.contains("URI=\"") else { return line }
        var result = ""
        var rest = Substring(line)
        while let r = rest.range(of: "URI=\"") {
            result += rest[..<r.lowerBound]
            let tail = rest[r.upperBound...]
            guard let q = tail.firstIndex(of: "\"") else {
                result += rest[r.lowerBound...]
                break
            }
            let rel = String(tail[..<q])
            result += "URI=\""
            if let abs = resolveAbsolute(rel, document: document),
               let sch = abs.scheme?.lowercased(), sch == "http" || sch == "https" {
                result += RbliveHlsProxyURL.playlistLine(for: abs)
            } else {
                result += rel
            }
            result += "\""
            rest = tail[tail.index(after: q)...]
        }
        result += String(rest)
        return result
    }
}

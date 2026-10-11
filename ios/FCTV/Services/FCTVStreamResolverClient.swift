import Foundation

/// Client for the proven Node `fctv33-stream-resolver` (localhost:3000).
/// Same contract as the web UI: `GET /api/resolve?matchId=&sportType=` → `playableUrl`.
enum FCTVStreamResolverClient {
    struct ResolveResponse: Decodable, Sendable {
        let name: String?
        let matchId: String?
        let sportType: Int?
        let streamUrl: String?
        let referer: String?
        let playableUrl: String?
        let error: String?
    }

    /// Base URL for the running resolver. Override with `FCTV_STREAM_RESOLVER_URL`.
    static var baseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["FCTV_STREAM_RESOLVER_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let u = URL(string: raw)
        {
            return u
        }
        return URL(string: "http://127.0.0.1:3000")!
    }

    /// Prefer the web resolver in DEBUG, or when `FCTV_STREAM_RESOLVER=1` / a custom base URL is set.
    /// Set `FCTV_STREAM_RESOLVER=0` to force the native Rblive path.
    static var isEnabled: Bool {
        if let flag = ProcessInfo.processInfo.environment["FCTV_STREAM_RESOLVER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            if flag == "0" || flag == "false" || flag == "no" || flag == "off" { return false }
            if flag == "1" || flag == "true" || flag == "yes" || flag == "on" { return true }
        }
        if ProcessInfo.processInfo.environment["FCTV_STREAM_RESOLVER_URL"] != nil { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// True when `url` is already a proxied playlist/segment from this resolver (`/api/hls`).
    static func isProxiedPlayableURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        guard host == "127.0.0.1" || host == "localhost" else { return false }
        return url.path.contains("/api/hls")
    }

    static func resolve(
        matchId: UInt64,
        sport: Sport,
        streamId: Int64? = nil
    ) async throws -> RbliveResolvedPlayback {
        let sportType = RbliveSportLanguage.sportTypeValue(sport)
        var components = URLComponents(url: baseURL.appendingPathComponent("api/resolve"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "matchId", value: String(matchId)),
            URLQueryItem(name: "sportType", value: String(sportType)),
        ]
        if let streamId {
            items.append(URLQueryItem(name: "streamId", value: String(streamId)))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw RbliveAPIError.invalidProtobuf("stream resolver URL")
        }

        fputs("[stream-resolver] GET \(url.absoluteString)\n", stderr)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let decoded = try? JSONDecoder().decode(ResolveResponse.self, from: data)

        if status != 200 {
            let message = decoded?.error
                ?? String(data: data, encoding: .utf8)
                ?? "resolve failed"
            fputs("[stream-resolver] HTTP \(status): \(message)\n", stderr)
            throw RbliveAPIError.http(status, message)
        }
        guard let playable = decoded?.playableUrl, let playableURL = URL(string: playable) else {
            throw RbliveAPIError.missingStreamURL
        }

        fputs(
            "[stream-resolver] ok name=\(decoded?.name ?? "") playable=\(playable.prefix(120))…\n",
            stderr
        )
        // Headers are applied by the Node HLS proxy; AVPlayer only needs the localhost URL.
        return RbliveResolvedPlayback(url: playableURL, extraHTTPHeaders: [:])
    }
}

import Foundation

/// Custom scheme so `AVAssetResourceLoader` intercepts every HLS request (playlists + segments),
/// mirroring OkHttp `HlsInjectFetcher` behaviour for `_sou` / `actionSouInject` / CSL.
enum RbliveHlsProxyURL {
    static let scheme = "rblivehls"
    private static let host = "local.playback"

    /// Wraps an `https?` master or media URL into a proxy URL consumed by `RbliveHlsAssetLoader`.
    ///
    /// The original URL is stored as **Base64URL** in query `u` so `&` / `%2F` in CDN paths
    /// cannot truncate or corrupt `URLComponents` round-trips.
    static func wrappingHTTPS(_ original: URL) -> URL? {
        guard let s = original.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.path = proxyPath(for: original)
        c.queryItems = [URLQueryItem(name: "u", value: encodeURL(original.absoluteString))]
        return c.url
    }

    private static func proxyPath(for original: URL) -> String {
        let ext = original.pathExtension.lowercased()
        switch ext {
        case "m3u8", "m3u":
            return "/playlist.m3u8"
        case "ts", "m4s", "mp4", "aac", "vtt", "key":
            return "/segment.\(ext)"
        default:
            if original.absoluteString.lowercased().contains(".m3u8") {
                return "/playlist.m3u8"
            }
            // CSL placeholders often end in `.json` / `.woff2` but carry MPEG-TS.
            return "/segment.ts"
        }
    }

    /// Decodes `u` query from a proxy URL into the underlying HTTP(S) URL string.
    static func underlyingURLString(from proxy: URL) -> String? {
        guard proxy.scheme?.lowercased() == scheme else { return nil }
        guard let raw = URLComponents(url: proxy, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "u" })?
            .value
        else { return nil }
        if let decoded = decodeURL(raw) { return decoded }
        // Backward-compat: older builds stored the plain URL.
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        return nil
    }

    /// Line to embed inside an `.m3u8` (no extra quoting).
    static func playlistLine(for absolute: URL) -> String {
        wrappingHTTPS(absolute)?.absoluteString ?? absolute.absoluteString
    }

    private static func encodeURL(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeURL(_ s: String) -> String? {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - (b64.count % 4)) % 4
        if pad > 0 { b64 += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

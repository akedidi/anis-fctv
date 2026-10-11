import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// HTTP client for `apis-data*.cfd` — mirrors OkHttp + `NetworkInterceptor` headers from the Android app.
actor RbliveHTTPClient {
    static let shared = RbliveHTTPClient()

    /// Default from Android 3.0.323 (`apis-data10…`); Firebase may override via `FCTV_DATA_API_HOST` / UserDefaults.
    private static let defaultAPIHost = "apis-data10.tcllu137fien.ru"

    private enum Keys {
        static let dataAPIHost = "fctv.rblive.data_api_host"
        static let userAgent = "fctv.rblive.user_agent"
        static let httpOrigin = "fctv.rblive.http_origin"
        static let httpReferer = "fctv.rblive.http_referer"
        static let parityAndroid = "fctv.rblive.parity_android"
        static let persistCookies = "fctv.rblive.persist_cookies"
    }

    private let session: URLSession
    private var lastRbSession: String?

    init() {
        let config: URLSessionConfiguration = Self.persistentCookiesEnabled() ? .default : .ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func lastSessionHeader() -> String? { lastRbSession }

    /// Drop a stale `rb-session` so the next API calls behave like a cold launch.
    /// Call after long background / on auth-like failures — an expired header poisons every request.
    func clearSession() {
        if lastRbSession != nil {
            fputs("[rblive] clearSession (stale rb-session dropped)\n", stderr)
        }
        lastRbSession = nil
    }

    /// Android `rbSession ?: deviceID` for `UrlTools.signPlayUrl` when the API omits `rb-session`.
    func stableDeviceId() -> String {
        let key = "fctv.rblive.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Resolved host (no scheme). Override: `FCTV_DATA_API_HOST` or `UserDefaults` key `fctv.rblive.data_api_host` (Firebase-style on Android).
    var dataAPIHost: String {
        resolvedDataAPIHost()
    }

    /// Same role as Android `AppUtils.rbUA()` for the playback stack (`HlsInjectManager.calcRBHeaders`).
    func rbPlaybackUserAgent() async -> String {
        await rbUserAgent()
    }

    /// `HlsInjectManager.calcRBHeaders` — P2P `rbHeaders` + `rbUA` + optional iframe (`trd`) from `UserDefaults`.
    func calcRBHeadersForPlayback() async -> [String: String] {
        let ua = await rbUserAgent()
        return await MainActor.run {
            RbliveHlsInjectEngine.calcRBHeaders(rbUserAgent: ua)
        }
    }

    private func rbUserAgent() async -> String {
        if let ua = ProcessInfo.processInfo.environment["FCTV_RB_USER_AGENT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            return ua
        }
        if let ua = UserDefaults.standard.string(forKey: Keys.userAgent)?.trimmingCharacters(in: .whitespacesAndNewlines), !ua.isEmpty {
            return ua
        }
        if Self.parityAndroidMode() {
            return Self.androidStyleRbUserAgent()
        }
        #if canImport(UIKit)
        return await MainActor.run {
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
            let system = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
            let model = UIDevice.current.model.replacingOccurrences(of: " ", with: "_")
            let tz = TimeZone.current.identifier.replacingOccurrences(of: "/", with: "-")
            let lang = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            return "rbapp/--dg-77-ios-\(build)/\(ver)/iOS_\(system)/\(model)/\(tz)/\(lang)"
        }
        #else
        return "rbapp/--dg-77-ios-1/1.0.0/iOS_unknown/Simulator/UTC/en"
        #endif
    }

    /// Android-style `rbapp` UA (structure aligned with 3.0.x builds). Enable with `FCTV_PARITY_ANDROID=1` or `UserDefaults` `fctv.rblive.parity_android`.
    private static func androidStyleRbUserAgent() -> String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.319"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "319"
        let tz = TimeZone.current.identifier.replacingOccurrences(of: "/", with: "-")
        let lang = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return "rbapp/--dg-77-android-\(build)/\(ver)/Android_14/generic/\(tz)/\(lang)"
    }

    private static func parityAndroidMode() -> Bool {
        let e = ProcessInfo.processInfo.environment["FCTV_PARITY_ANDROID"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e == "1" || e == "true" || e == "yes" { return true }
        return UserDefaults.standard.bool(forKey: Keys.parityAndroid)
    }

    private static func persistentCookiesEnabled() -> Bool {
        if parityAndroidMode() { return true }
        let e = ProcessInfo.processInfo.environment["FCTV_PERSIST_COOKIES"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e == "1" || e == "true" || e == "yes" { return true }
        return UserDefaults.standard.bool(forKey: Keys.persistCookies)
    }

    private func resolvedDataAPIHost() -> String {
        if let raw = ProcessInfo.processInfo.environment["FCTV_DATA_API_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Self.stripToHost(raw)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.dataAPIHost)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Self.stripToHost(raw)
        }
        return Self.defaultAPIHost
    }

    private static func stripToHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        if let i = s.firstIndex(of: "/") {
            s = String(s[..<i])
        }
        if let i = s.firstIndex(of: ":") {
            s = String(s[..<i])
        }
        return s
    }

    private func applyDefaultHeaders(_ request: inout URLRequest, attachSession: Bool = true) async {
        request.setValue(await rbUserAgent(), forHTTPHeaderField: "User-Agent")
        let origin = resolvedHTTPOrigin()
        let referer = resolvedHTTPReferer()
        request.setValue(origin, forHTTPHeaderField: "origin")
        request.setValue(referer, forHTTPHeaderField: "referer")
        if attachSession, let s = lastRbSession {
            request.setValue(s, forHTTPHeaderField: "rb-session")
        }
    }

    private func resolvedHTTPOrigin() -> String {
        if let o = ProcessInfo.processInfo.environment["FCTV_HTTP_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        if let o = UserDefaults.standard.string(forKey: Keys.httpOrigin)?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        return "https://www.rbtv77.com"
    }

    private func resolvedHTTPReferer() -> String {
        if let o = ProcessInfo.processInfo.environment["FCTV_HTTP_REFERER"]?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        if let o = UserDefaults.standard.string(forKey: Keys.httpReferer)?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return o
        }
        return "https://teagan01bp.mvksstick9uq6cprotection.cfd/"
    }

    /// `GET /api/common/bs` — returns raw `PBResponse` bytes.
    func getBodySignature(codes: [Int], sportType: Int32?, matchId: UInt64?, stream: Bool, cachePriority: Bool) async throws -> Data {
        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = resolvedDataAPIHost()
        comp.path = "/api/common/bs"
        var items: [URLQueryItem] = codes.map { URLQueryItem(name: "code", value: String($0)) }
        if let sportType {
            items.append(URLQueryItem(name: "sportType", value: String(sportType)))
        }
        if let matchId {
            items.append(URLQueryItem(name: "matchId", value: String(matchId)))
        }
        items.append(URLQueryItem(name: "stream", value: stream ? "true" : "false"))
        items.append(URLQueryItem(name: "cachePriority", value: cachePriority ? "true" : "false"))
        comp.queryItems = items
        guard let url = comp.url else { throw RbliveAPIError.invalidProtobuf("bad bs url") }
        do {
            return try await performBodySignature(url: url, attachSession: true)
        } catch let error as RbliveAPIError {
            guard lastRbSession != nil, shouldRetryWithoutSession(error) else { throw error }
            clearSession()
            fputs("[rblive] retry /api/common/bs without rb-session after \(error.localizedDescription)\n", stderr)
            return try await performBodySignature(url: url, attachSession: false)
        }
    }

    private func performBodySignature(url: URL, attachSession: Bool) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        await applyDefaultHeaders(&req, attachSession: attachSession)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RbliveAPIError.http(-1, nil) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RbliveAPIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    func getMatchLive(pathParams6: String, versionToken: String, language: Int32, sportType: Int32, stream: Bool) async throws -> Data {
        let path = "/sfver\(pathParams6)\(versionToken)/api/match/live"
        return try await getProtobuf(path: path, query: [
            URLQueryItem(name: "language", value: String(language)),
            URLQueryItem(name: "sportType", value: String(sportType)),
            URLQueryItem(name: "stream", value: stream ? "true" : "false"),
        ])
    }

    func getMatchDetail(pathParams6: String, versionToken: String, matchId: UInt64, language: Int32, sportType: Int32, stream: Bool) async throws -> Data {
        let path = "/sfver\(pathParams6)\(versionToken)/api/match/detail"
        return try await getProtobuf(path: path, query: [
            URLQueryItem(name: "matchId", value: String(matchId)),
            URLQueryItem(name: "language", value: String(language)),
            URLQueryItem(name: "sportType", value: String(sportType)),
            URLQueryItem(name: "stream", value: stream ? "true" : "false"),
        ])
    }

    func getMatchLineup(pathParams6: String, versionToken: String, matchId: UInt64, language: Int32, sportType: Int32) async throws -> Data {
        let path = "/sfver\(pathParams6)\(versionToken)/api/match/lineup"
        return try await getProtobuf(path: path, query: [
            URLQueryItem(name: "matchId", value: String(matchId)),
            URLQueryItem(name: "language", value: String(language)),
            URLQueryItem(name: "sportType", value: String(sportType)),
        ])
    }

    func getMatchEvent(pathParams6: String, versionToken: String, matchId: UInt64, language: Int32, sportType: Int32) async throws -> Data {
        let path = "/sfver\(pathParams6)\(versionToken)/api/match/event"
        return try await getProtobuf(path: path, query: [
            URLQueryItem(name: "matchId", value: String(matchId)),
            URLQueryItem(name: "language", value: String(language)),
            URLQueryItem(name: "sportType", value: String(sportType)),
        ])
    }

    func getStreamDetailSigned(
        pathParams6: String,
        versionToken: String,
        matchId: UInt64,
        sportType: Int32,
        streamId: Int64,
        siteType: Int32,
        continent: String,
        country: String,
        digit: String,
        withOriginal: Bool
    ) async throws -> Data {
        let path = "/sfver\(pathParams6)\(versionToken)/api/stream/detail"
        return try await getProtobuf(path: path, query: [
            URLQueryItem(name: "matchId", value: String(matchId)),
            URLQueryItem(name: "sportType", value: String(sportType)),
            URLQueryItem(name: "streamId", value: String(streamId)),
            URLQueryItem(name: "siteType", value: String(siteType)),
            URLQueryItem(name: "continent", value: continent),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "digit", value: digit),
            URLQueryItem(name: "withOriginal", value: withOriginal ? "true" : "false"),
        ], captureSession: true)
    }

    func getStreamDetail(matchId: UInt64, sportType: Int32, streamId: Int64, siteType: Int32, continent: String, country: String, digit: String, withOriginal: Bool) async throws -> Data {
        let data = try await getProtobuf(path: "/api/stream/detail", query: [
            URLQueryItem(name: "matchId", value: String(matchId)),
            URLQueryItem(name: "sportType", value: String(sportType)),
            URLQueryItem(name: "streamId", value: String(streamId)),
            URLQueryItem(name: "siteType", value: String(siteType)),
            URLQueryItem(name: "continent", value: continent),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "digit", value: digit),
            URLQueryItem(name: "withOriginal", value: withOriginal ? "true" : "false"),
        ], captureSession: true)
        return data
    }

    func postJSON(path: String, jsonBody: Data) async throws -> Data {
        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = resolvedDataAPIHost()
        comp.path = path
        guard let url = comp.url else { throw RbliveAPIError.invalidProtobuf("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = jsonBody
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await applyDefaultHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RbliveAPIError.http(-1, nil) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RbliveAPIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    func getProtobuf(path: String, query: [URLQueryItem], captureSession: Bool = false) async throws -> Data {
        do {
            return try await performGetProtobuf(path: path, query: query, captureSession: captureSession, attachSession: true)
        } catch let error as RbliveAPIError {
            // Stale rb-session often yields 401/403 (or odd upstream codes). Drop it and retry once like a cold start.
            guard lastRbSession != nil, shouldRetryWithoutSession(error) else { throw error }
            clearSession()
            fputs("[rblive] retry \(path) without rb-session after \(error.localizedDescription)\n", stderr)
            return try await performGetProtobuf(path: path, query: query, captureSession: captureSession, attachSession: false)
        }
    }

    private func shouldRetryWithoutSession(_ error: RbliveAPIError) -> Bool {
        if case let .http(code, _) = error {
            return code == 401 || code == 403 || code == 419 || code == 440 || code == 498
        }
        return false
    }

    private func performGetProtobuf(
        path: String,
        query: [URLQueryItem],
        captureSession: Bool,
        attachSession: Bool
    ) async throws -> Data {
        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = resolvedDataAPIHost()
        comp.path = path
        comp.queryItems = query
        guard let url = comp.url else { throw RbliveAPIError.invalidProtobuf("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // Pull-to-refresh / live list must always hit the network.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        await applyDefaultHeaders(&req, attachSession: attachSession)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RbliveAPIError.http(-1, nil) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RbliveAPIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        // Only keep a session from a successful response — error bodies can carry stale cookies.
        if captureSession {
            if let s = http.value(forHTTPHeaderField: "rb-session")
                ?? http.value(forHTTPHeaderField: "Rb-Session") {
                lastRbSession = s
            } else {
                var fields: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String { fields[ks] = vs }
                }
                if let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                    .first(where: { $0.name == "rb-session" }) {
                    lastRbSession = cookie.value
                }
            }
            if ProcessInfo.processInfo.environment["FCTV_DEBUG_API"] == "1" {
                fputs("[rblive] rb-session \(lastRbSession == nil ? "missing" : "ok len=\(lastRbSession!.count)")\n", stderr)
            }
        }
        if ProcessInfo.processInfo.environment["FCTV_DEBUG_API"] == "1", path.contains("stream/detail") {
            let hex = data.prefix(min(96, data.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            let asText = String(data: data.prefix(200), encoding: .utf8) ?? ""
            fputs("[debug] \(path) bytes=\(data.count) hex96=\(hex) text200=\(asText)\n", stderr)
        }
        return data
    }
}

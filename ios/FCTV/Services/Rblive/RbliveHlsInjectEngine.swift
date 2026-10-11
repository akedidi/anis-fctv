import Foundation

// MARK: - Remote defaults (no Firebase on iOS — UserDefaults overrides)

/// Parity with `ParamsManager` + `HlsInjectManager` + `AppEnv` STINJ / P2P / web-client blobs (3.0.319).
@MainActor
enum RbliveHlsInjectEngine {

    private static let udInjectEnableKey = "fctv.rblive.stinj_enable"
    private static let udSTINJBase64Key = "fctv.rblive.stinj_b64"
    private static let udP2PV3JSONKey = "fctv.rblive.p2p_config_v3_json"
    private static let udRBWebClientJSONKey = "fctv.rblive.rb_web_client_json"

    /// Same base64 as `App.java` `AppEnvParams` STINJ (decoded by `RBCrypto.fromBase64` → JSON array on Android).
    private static let embeddedSTINJBase64 =
        "W3siZW5hYmxlIjp0cnVlLCJobHNJbmplY3RUeXBlIjozLCJibGFja0NvdW50cnlDb2RlcyI6W10sInNpbXBsZVVybEluamVjdCI6eyJqdWRnZVBhdHRlcm4iOiJodHRwLio/L3YzYi8uKj9uVUUwcFVaNllsOWZuS015TDJFaFlhVzFvS0FqbzNXMFl6QWlvRC4qPy8uKlxcLnRzLioiLCJpc1JhbmRvbVVBIjp0cnVlLCJleHRyYUhlYWRlcnMiOnsiYWNjZXB0IjoiKi8qIiwiYWNjZXB0LWxhbmd1YWdlIjoiZW47cT0wLjgsamE7cT0wLjcsemgtVFc7cT0wLjYsY2E7cT0wLjUsY3k7cT0wLjQiLCJjYWNoZS1jb250cm9sIjoibm8tY2FjaGUiLCJhY2NlcHQtZW5jb2RpbmciOiJpZGVudGl0eSIsIlgtUGxheWJhY2stU2Vzc2lvbi1JZCI6IjgzQURENTE0LUUwMEMtNDM3Ri1CMEY0LTIzMzUwRERENjFCOSIsInJlZmVyZXIiOiJodHRwczovL3hpYW9saW4ubGl2ZS8iLCJvcmlnaW4iOiJodHRwczovL3hpYW9saW4ubGl2ZSJ9fX1d"

    /// Minimal `P2PConfigV3` wrapper: only `basicConfig.rbHeaders` is required for `calcRBHeaders` (see `ParamsManager.DEF_COMMON_P2P_V3`).
    private static let embeddedP2PV3JSON = """
    {"basicConfig":{"rbHeaders":{"referer":"https://teagan01bp.mvksstick9uq6cprotection.cfd/","origin":"https://teagan01bp.mvksstick9uq6cprotection.cfd"}}}
    """

    private static let cslQueryNames = ["_ctump", "_ctutt", "_ctuph"]

    enum HlsInjectType: Int {
        case unsupported = 0
        case playlistSimpleInject = 1
        case segmentSimpleInject = 2
        case segmentSouInject = 3
    }

    /// Mirrors `ParamsManager.getInjectEnable()` defaulting to `AppEnv` STINJ_ENABLE (`false` in shipped `App.java`).
    /// UI tests may pass `--uitesting-stinj-enabled` to force segment/playlist inject on.
    static var injectEnabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("--uitesting-stinj-enabled") {
            return true
        }
        if UserDefaults.standard.object(forKey: udInjectEnableKey) != nil {
            return UserDefaults.standard.bool(forKey: udInjectEnableKey)
        }
        return false
    }

    // MARK: - CSL query strip (`CommonUtils.removeCSLQuery`)

    static func removeCSLQuery(from urlString: String) -> String {
        guard var comp = URLComponents(string: urlString) else { return urlString }
        let strip = Set(cslQueryNames)
        if let items = comp.queryItems {
            let kept = items.filter { !strip.contains($0.name) }
            comp.queryItems = kept.isEmpty ? nil : kept
        }
        return comp.string ?? urlString
    }

    // MARK: - Strategies (STINJ)

    private struct HlsStrategyDTO: Decodable {
        let enable: Bool
        let hlsInjectType: Int
        let blackCountryCodes: [String]?
        let whiteCountryCodes: [String]?
        let simpleUrlInject: SimpleUrlInjectDTO?
        let souSegmentInject: SimpleUrlInjectDTO?
    }

    private struct SimpleUrlInjectDTO: Decodable {
        let judgePattern: String?
        let replacePattern: String?
        let toUrl: String?
        let isRandomUA: Bool?
        let extraHeaders: [String: String]?
    }

    private static func loadStrategiesJSON() -> Data? {
        let b64 = UserDefaults.standard.string(forKey: udSTINJBase64Key) ?? embeddedSTINJBase64
        guard let decoded = Data(base64Encoded: b64),
              let s = String(data: decoded, encoding: .utf8),
              let out = s.data(using: .utf8)
        else { return nil }
        return out
    }

    private static func decodedStrategies() -> [HlsStrategyDTO] {
        guard let data = loadStrategiesJSON(),
              let arr = try? JSONDecoder().decode([HlsStrategyDTO].self, from: data)
        else { return [] }
        return arr
    }

    private static func userCountryCode() -> String {
        if let r = Locale.current.region?.identifier, !r.isEmpty { return r }
        return "US"
    }

    private static func passesCountryFilter(_ s: HlsStrategyDTO) -> Bool {
        let country = userCountryCode()
        let black = s.blackCountryCodes ?? []
        let white = s.whiteCountryCodes ?? []
        if !black.isEmpty {
            return !black.contains(country)
        }
        if !white.isEmpty {
            return white.contains(country)
        }
        return true
    }

    private static func strategies(for type: HlsInjectType) -> [HlsStrategyDTO] {
        guard injectEnabled else { return [] }
        return decodedStrategies().filter { s in
            s.enable && s.hlsInjectType == type.rawValue && passesCountryFilter(s)
        }
    }

    // MARK: - SimpleUrlInject (`SimpleUrlInject.java`)

    private static func isJudgeHit(judgePattern: String, url: String) -> Bool {
        guard !judgePattern.isEmpty else { return false }
        guard let re = try? NSRegularExpression(pattern: judgePattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(url.startIndex..., in: url)
        return re.firstMatch(in: url, options: [], range: range) != nil
    }

    private static func replaceUrl(dto: SimpleUrlInjectDTO, url: String) -> String {
        let to = dto.toUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if to.isEmpty { return url }
        let pat = (dto.replacePattern?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? dto.judgePattern
            ?? ""
        guard !pat.isEmpty else { return url }
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return url }
        let range = NSRange(url.startIndex..., in: url)
        let out = re.stringByReplacingMatches(in: url, options: [], range: range, withTemplate: to)
        return removeCSLQuery(from: out)
    }

    /// `HlsInjectManager.actionSouInject` — `_sou` query + `bruDecode` + trim.
    static func souUrl(from urlString: String) -> String? {
        guard let u = URL(string: urlString),
              let comp = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let items = comp.queryItems,
              let raw = items.first(where: { $0.name == "_sou" })?.value
        else { return nil }
        guard let decoded = try? RbliveStreamCrypto.bruDecode(raw) else { return nil }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - P2P rbHeaders + RB web client (`ParamsManager` / `RBWebClientConfig`)

    private struct P2PBasicDTO: Decodable {
        let rbHeaders: [String: String]?
    }

    private struct P2POuterDTO: Decodable {
        let basicConfig: P2PBasicDTO?
    }

    private struct RBWebClientConfigDTO: Decodable {
        let iframePlayerDomains: [String]?
    }

    private static func loadP2PRBHeaders() -> [String: String] {
        let json = UserDefaults.standard.string(forKey: udP2PV3JSONKey) ?? embeddedP2PV3JSON
        guard let data = json.data(using: .utf8),
              let outer = try? JSONDecoder().decode(P2POuterDTO.self, from: data),
              let h = outer.basicConfig?.rbHeaders
        else { return [:] }
        return h
    }

    private static func loadRBWebClientMap() -> [String: RBWebClientConfigDTO] {
        guard let json = UserDefaults.standard.string(forKey: udRBWebClientJSONKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: RBWebClientConfigDTO].self, from: data)
        else { return [:] }
        return map
    }

    /// `HlsInjectManager.getPlayerHeadersByIframe` — first `iframePlayerDomains` entry for key `trd`.
    private static func playerHeadersByIframe() -> [String: String] {
        guard let cfg = loadRBWebClientMap()["trd"],
              let domains = cfg.iframePlayerDomains,
              let first = domains.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty
        else { return [:] }
        var string = first
        if !string.lowercased().hasPrefix("http") {
            string = "https://" + string
        }
        return ["referer": string + "/", "origin": string]
    }

    /// `HlsInjectManager.calcRBHeaders` — P2P `rbHeaders` + `AppUtils.rbUA()` + iframe (case-insensitive key merge; iframe wins on clash).
    static func calcRBHeaders(rbUserAgent: String) -> [String: String] {
        var m: [String: String] = [:]
        for (k, v) in loadP2PRBHeaders() {
            m[k.lowercased()] = v
        }
        m["user-agent"] = rbUserAgent
        for (k, v) in playerHeadersByIframe() {
            m[k.lowercased()] = v
        }
        return m
    }

    private static func randomUserAgentString() -> String? {
        if let u = UserDefaults.standard.string(forKey: "fctv.rblive.random_ua_override"), !u.isEmpty {
            return u
        }
        let pool = [
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
        ]
        return pool.randomElement()
    }

    /// Merge order matches `HlsInjectManager.actionSimpleInject`: `calcRBHeaders` → `srcHeaders` → `extraHeaders` → optional random UA.
    private static func mergedInjectHeaders(
        calc: [String: String],
        srcHeaders: [String: String],
        extra: [String: String],
        randomUA: Bool
    ) -> [String: String] {
        var m = calc
        for (k, v) in srcHeaders { m[k.lowercased()] = v }
        for (k, v) in extra { m[k.lowercased()] = v }
        if randomUA, let ua = randomUserAgentString() {
            m["user-agent"] = ua
        }
        return m
    }

    /// `HlsInjectManager.actionSimpleInject`
    static func actionSimpleInject(
        type: HlsInjectType,
        url: String,
        srcHeaders: [String: String],
        rbUserAgent: String
    ) -> (url: String, headers: [String: String])? {
        guard injectEnabled else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        var chosen: (HlsStrategyDTO, SimpleUrlInjectDTO)?
        for s in strategies(for: type) {
            guard let inj = s.simpleUrlInject else { continue }
            let judge = inj.judgePattern ?? ""
            if isJudgeHit(judgePattern: judge, url: trimmed) {
                chosen = (s, inj)
                break
            }
        }
        guard let (_, inj) = chosen else { return nil }

        let newURL = replaceUrl(dto: inj, url: trimmed)
        let calc = calcRBHeaders(rbUserAgent: rbUserAgent)
        let extra = inj.extraHeaders ?? [:]
        let hdr = mergedInjectHeaders(
            calc: calc,
            srcHeaders: srcHeaders,
            extra: extra,
            randomUA: inj.isRandomUA ?? false
        )
        return (newURL, hdr)
    }

    /// `HlsInjectManager.actionSouInject`
    static func actionSouInject(
        type: HlsInjectType,
        url: String,
        srcHeaders: [String: String],
        rbUserAgent: String
    ) -> (url: String, headers: [String: String])? {
        guard injectEnabled else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        var chosen: (HlsStrategyDTO, SimpleUrlInjectDTO)?
        for s in strategies(for: type) {
            guard let inj = s.simpleUrlInject else { continue }
            let judge = inj.judgePattern ?? ""
            if isJudgeHit(judgePattern: judge, url: trimmed) {
                chosen = (s, inj)
                break
            }
        }
        guard let (_, inj) = chosen else { return nil }
        guard let sou = souUrl(from: trimmed) else { return nil }

        let calc = calcRBHeaders(rbUserAgent: rbUserAgent)
        let extra = inj.extraHeaders ?? [:]
        let hdr = mergedInjectHeaders(
            calc: calc,
            srcHeaders: srcHeaders,
            extra: extra,
            randomUA: inj.isRandomUA ?? false
        )
        return (sou, hdr)
    }
}

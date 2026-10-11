import CryptoKit
import Foundation

/// CDN Smart Link (CSL) — port of `fctv33-stream-resolver` `src/proxy/csl.ts`
/// and Android `CdnSmartLinkManager` / `CslSegment.convert`.
///
/// Live playlists list placeholder segment URLs with `_ctump` / `_ctuph` / `_ctutt`.
/// Raw CDN fetches 302/403/487; real MPEG-TS comes from signed CTU hosts.
enum RbliveCslResolver: Sendable {

    struct Config: Sendable {
        var salt: String = "00"
        var maxRetryTimes: Int = 2
        var minFetchTimeout: Double = 3.2
        var country: String?
        var continent: String?
    }

    struct CtuItem: Sendable {
        let ccode: String
        let url: String
        let timeoutSec: Double
    }

    private static let udSaltKey = "fctv.rblive.csl_salt"
    private static let udConfigJSONKey = "fctv.rblive.csl_config_json"

    static func isCslSegmentURL(_ urlString: String) -> Bool {
        guard let u = URL(string: urlString),
              let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        return items.contains { $0.name == "_ctump" }
    }

    /// Cached salt from `/api/common/params` (`common:cdnSmartLink`) or default `"00"`.
    static func currentConfig(geoCountry: String? = nil, geoContinent: String? = nil) -> Config {
        var cfg = Config()
        if let salt = UserDefaults.standard.string(forKey: udSaltKey), !salt.isEmpty {
            cfg.salt = salt
        }
        if let json = UserDefaults.standard.string(forKey: udConfigJSONKey),
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let auth = obj["auth"] as? [String: Any], let s = auth["salt"] as? String, !s.isEmpty {
                cfg.salt = s
            }
            if let n = obj["maxRetryTimes"] as? Int { cfg.maxRetryTimes = n }
            if let n = obj["maxRetryTimes"] as? Double { cfg.maxRetryTimes = Int(n) }
            if let n = obj["minFetchTimeout"] as? Double { cfg.minFetchTimeout = n }
        }
        cfg.country = geoCountry
        cfg.continent = geoContinent
        return cfg
    }

    static func storeParamsCdnSmartLinkJSON(_ json: String) {
        UserDefaults.standard.set(json, forKey: udConfigJSONKey)
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = obj["auth"] as? [String: Any],
           let salt = auth["salt"] as? String {
            UserDefaults.standard.set(salt, forKey: udSaltKey)
        }
    }

    static func resolveCtuURLs(segmentURL: String, config: Config) -> [CtuItem] {
        guard let comps = URLComponents(string: segmentURL) else { return [] }
        let items = comps.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let ctumpRaw = q("_ctump"),
              let ctump = try? RbliveStreamCrypto.bruDecode(ctumpRaw),
              !ctump.isEmpty
        else { return [] }
        let ctuph = (try? RbliveStreamCrypto.bruDecode(q("_ctuph") ?? "")) ?? ""
        let ctuttStr = (try? RbliveStreamCrypto.bruDecode(q("_ctutt") ?? "")) ?? ""
        let timeout = Double(ctuttStr).flatMap { $0 > 0 ? $0 : nil } ?? config.minFetchTimeout

        var out: [CtuItem] = []
        for part in ctump.split(separator: ",") {
            let s = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let at = s.firstIndex(of: "@") else { continue }
            let left = String(s[..<at])
            let host = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { continue }
            let ccode = left.split(separator: ":").first.map(String.init) ?? left
            let raw = "https://\(host)\(ctuph)"
            out.append(CtuItem(ccode: ccode, url: signCtuURL(raw, salt: config.salt), timeoutSec: timeout))
        }
        return orderCtuItems(out, config: config)
    }

    static func orderCtuItems(_ items: [CtuItem], config: Config) -> [CtuItem] {
        var ordered: [CtuItem] = []
        var seen = Set<String>()
        func push(_ item: CtuItem?) {
            guard let item, !seen.contains(item.url) else { return }
            seen.insert(item.url)
            ordered.append(item)
        }
        if let cont = config.continent, let country = config.country {
            push(items.first { $0.ccode == "\(cont)-\(country)" })
        }
        if let cont = config.continent {
            push(items.first { $0.ccode == cont })
        }
        push(items.first { $0.ccode == "WW" })
        for item in items { push(item) }
        return ordered
    }

    static func signCtuURL(_ rawURL: String, salt: String) -> String {
        guard var comps = URLComponents(string: rawURL) else { return rawURL }
        let file = URL(string: rawURL)?.lastPathComponent ?? ""
        let ver = comps.queryItems?.first { $0.name == "_ver" }?.value ?? ""
        let digest = Insecure.MD5.hash(data: Data("\(file),\(ver),\(salt)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        var q = comps.queryItems?.filter { $0.name != "_s2" } ?? []
        q.append(URLQueryItem(name: "_s2", value: hex))
        comps.queryItems = q
        return comps.string ?? rawURL
    }
}

import Foundation

/// Country / region helpers for stream rows and league badges (inspired by streamsports).
enum CountryHelper {
    /// Localized English region name for an ISO-3166 alpha-2 code.
    static func name(for code: String) -> String? {
        let id = Locale(identifier: "en_US")
        return id.localizedString(forRegionCode: code.uppercased())
    }

    /// Flag emoji from an ISO-3166 alpha-2 code.
    static func flagEmoji(for code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 2,
              upper.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) })
        else { return nil }
        // EU / continental pseudo-codes have no flag emoji.
        if upper == "EU" || upper == "AS" || upper == "AF" { return nil }
        let base: UInt32 = 127_397
        var out = String.UnicodeScalarView()
        for u in upper.unicodeScalars {
            guard let s = UnicodeScalar(base + u.value) else { return nil }
            out.append(s)
        }
        return String(out)
    }

    /// flagcdn URL for a 2-letter code (skips non-ISO pseudo codes).
    static func flagCDNURL(for code: String, width: Int = 40) -> URL? {
        let c = code.lowercased()
        guard c.count == 2, c != "eu", c != "as", c != "af" else { return nil }
        return URL(string: "https://flagcdn.com/w\(width)/\(c).png")
    }

    /// Best-effort country from a stream/channel label + optional match region.
    /// Does not invent a country when nothing matches — returns empty code.
    static func infer(fromStreamName streamName: String, matchRegion: String) -> (label: String, code: String?) {
        let blob = "\(streamName) \(matchRegion)".trimmingCharacters(in: .whitespacesAndNewlines)
        if blob.isEmpty { return ("", nil) }

        let lower = blob.lowercased()

        // Trailing / embedded ISO tokens: "TD EN", "Pam US", "Sky DE", "xxx-FR"
        if let code = trailingISOCode(in: streamName) {
            return (Self.name(for: code) ?? code, code)
        }

        // Channel / broadcast brand heuristics.
        let brandMap: [(String, String)] = [
            ("bein sports fr", "FR"), ("bein sport fr", "FR"), ("canal+", "FR"), ("canal +", "FR"),
            ("tf1", "FR"), ("m6", "FR"), ("rmc sport", "FR"), ("eurosport fr", "FR"),
            ("sky sport de", "DE"), ("dazn de", "DE"),
            ("sky uk", "GB"), ("bt sport", "GB"), ("tnt sports", "GB"),
            ("espn", "US"), ("fox sports", "US"), ("pam us", "US"),
            ("raisport", "IT"), ("sky italia", "IT"), ("dazn it", "IT"),
            ("movistar", "ES"), ("dazn es", "ES"),
            ("sport tv", "PT"), ("viaplay", "SE"),
            ("polsat", "PL"), ("eleven sports pl", "PL"),
            ("ssc", "SA"), ("abu dhabi", "AE"),
            ("td en", "GB"), ("td uk", "GB"),
        ]
        for (needle, code) in brandMap where lower.contains(needle) {
            let normalized = code == "UK" ? "GB" : code
            return (Self.name(for: normalized) ?? normalized, normalized)
        }

        // Parenthetical / bracketed ISO: "(FR)", "[DE]"
        for p in [#"\(([A-Za-z]{2})\)"#, #"\[([A-Za-z]{2})\]"#] {
            if let r = blob.range(of: p, options: .regularExpression) {
                let token = String(blob[r]).filter(\.isLetter).uppercased()
                let normalized = token == "UK" ? "GB" : token
                if acceptedCodes.contains(normalized), let label = Self.name(for: normalized) {
                    return (label, normalized)
                }
            }
        }

        // Match region as plain label (e.g. "England", "Europe", "Paraguay")
        let region = matchRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !region.isEmpty {
            if let code = regionToCode[region.lowercased()] {
                // Continental codes: keep label, no inventing a fake national flag later.
                if code == "EU" || code == "AS" || code == "AF" {
                    return (region, nil)
                }
                return (Self.name(for: code) ?? region, code)
            }
            return (region, nil)
        }
        return ("", nil)
    }

    /// Detects trailing country tokens in channel names: `TD EN`, `Pam US`, `Foo-FR`.
    private static func trailingISOCode(in streamName: String) -> String? {
        let trimmed = streamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let patterns = [
            #"\b([A-Za-z]{2})$"#,
            #"[-_/]([A-Za-z]{2})$"#,
            #"\b([A-Za-z]{2})\s*$"#,
        ]
        for p in patterns {
            if let r = trimmed.range(of: p, options: .regularExpression) {
                let token = String(trimmed[r]).filter(\.isLetter).uppercased()
                var normalized = token
                if normalized == "UK" || normalized == "EN" { normalized = "GB" }
                // Avoid treating short brand tokens (HD, SD, 4K-like) as countries.
                let banned: Set<String> = ["HD", "SD", "UHD", "LQ", "HQ", "OK", "TV", "FC"]
                if banned.contains(normalized) { continue }
                if acceptedCodes.contains(normalized) { return normalized }
            }
        }
        return nil
    }

    private static let acceptedCodes: Set<String> = [
        "FR", "DE", "ES", "IT", "PT", "NL", "PL", "SE", "NO", "DK", "FI",
        "GB", "US", "CA", "BR", "AR", "MX", "AU", "NZ", "JP", "KR", "CN",
        "IN", "SA", "AE", "QA", "TR", "RU", "UA", "BE", "CH", "AT", "IE", "ZA",
        "PY", "BD", "AF", "PK", "LK", "JM", "GR", "CZ", "RO", "HU", "HR",
    ]

    /// Unique keys only — duplicate dictionary literals crash at runtime.
    private static let regionToCode: [String: String] = [
        "england": "GB", "united kingdom": "GB", "uk": "GB", "great britain": "GB",
        "scotland": "GB", "wales": "GB",
        "france": "FR", "spain": "ES", "germany": "DE", "italy": "IT",
        "portugal": "PT", "netherlands": "NL", "holland": "NL",
        "belgium": "BE", "switzerland": "CH", "austria": "AT", "ireland": "IE",
        "usa": "US", "united states": "US", "america": "US",
        "brazil": "BR", "argentina": "AR", "mexico": "MX",
        "japan": "JP", "korea": "KR", "china": "CN",
        "australia": "AU", "new zealand": "NZ",
        "turkey": "TR", "saudi arabia": "SA", "uae": "AE", "qatar": "QA",
        "europe": "EU", "asia": "AS", "africa": "AF",
        "south america": "SA", "north america": "US", "oceania": "AU",
        "paraguay": "PY",
        "l'europe": "EU", "europeen": "EU", "européen": "EU",
        "south africa": "ZA", "bangladesh": "BD", "afghanistan": "AF",
        "india": "IN", "pakistan": "PK", "sri lanka": "LK", "west indies": "JM",
        "greece": "GR", "czech": "CZ", "czechia": "CZ", "romania": "RO",
        "hungary": "HU", "croatia": "HR",
    ]
}

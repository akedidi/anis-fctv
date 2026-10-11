import Foundation

/// `continent` / `country` query values for `/api/stream/detail` — Android sends real geo; iOS used to send empty strings.
enum RbliveGeoParameters {
    private enum Keys {
        static let country = "fctv.rblive.api_country"
        static let continent = "fctv.rblive.api_continent"
    }

    /// ISO 3166-1 alpha-2 (e.g. `FR`, `US`).
    nonisolated static func streamDetailCountryCode() -> String {
        if let o = ProcessInfo.processInfo.environment["FCTV_API_COUNTRY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           o.count == 2 {
            return o.uppercased()
        }
        if let o = UserDefaults.standard.string(forKey: Keys.country)?.trimmingCharacters(in: .whitespacesAndNewlines),
           o.count == 2 {
            return o.uppercased()
        }
        return (Locale.current.region?.identifier ?? "US").uppercased()
    }

    /// Short continent code (`EU`, `NA`, `AS`, `AF`, `SA`, `OC`) inferred from country unless overridden.
    nonisolated static func streamDetailContinent() -> String {
        if let o = ProcessInfo.processInfo.environment["FCTV_API_CONTINENT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !o.isEmpty {
            return o.uppercased()
        }
        if let o = UserDefaults.standard.string(forKey: Keys.continent)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !o.isEmpty {
            return o.uppercased()
        }
        return continent(forISOCountry: streamDetailCountryCode())
    }

    nonisolated private static func continent(forISOCountry cc: String) -> String {
        let c = cc.uppercased()

        let europe: Set<String> = [
            "AD", "AL", "AT", "AX", "BA", "BE", "BG", "BY", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI",
            "FO", "FR", "GB", "GG", "GI", "GR", "HR", "HU", "IE", "IM", "IS", "IT", "JE", "LI", "LT", "LU",
            "LV", "MC", "MD", "ME", "MK", "MT", "NL", "NO", "PL", "PT", "RO", "RS", "RU", "SE", "SI", "SJ",
            "SK", "SM", "UA", "VA", "XK",
        ]
        if europe.contains(c) { return "EU" }

        let asia: Set<String> = [
            "AE", "AF", "AM", "AZ", "BD", "BH", "BN", "BT", "CC", "CN", "CX", "GE", "HK", "ID", "IL", "IN",
            "IO", "IQ", "IR", "JO", "JP", "KG", "KH", "KP", "KR", "KW", "KZ", "LA", "LB", "LK", "MM", "MN",
            "MO", "MV", "MY", "NP", "OM", "PH", "PK", "PS", "QA", "SA", "SG", "SY", "TH", "TJ", "TL", "TM",
            "TR", "TW", "UZ", "VN", "YE",
        ]
        if asia.contains(c) { return "AS" }

        let africa: Set<String> = [
            "AO", "BF", "BI", "BJ", "BW", "CD", "CF", "CG", "CI", "CM", "CV", "DJ", "DZ", "EG", "EH", "ER",
            "ET", "GA", "GH", "GM", "GN", "GQ", "GW", "KE", "KM", "LR", "LS", "LY", "MA", "MG", "ML", "MR",
            "MU", "MW", "MZ", "NA", "NE", "NG", "RE", "RW", "SC", "SD", "SH", "SL", "SN", "SO", "SS", "ST",
            "SZ", "TD", "TG", "TN", "TZ", "UG", "YT", "ZA", "ZM", "ZW",
        ]
        if africa.contains(c) { return "AF" }

        let oceania: Set<String> = [
            "AS", "AU", "CK", "FJ", "FM", "GU", "KI", "MH", "MP", "NC", "NF", "NR", "NU", "NZ", "PF", "PG",
            "PN", "PW", "SB", "TK", "TO", "TV", "UM", "VU", "WF", "WS",
        ]
        if oceania.contains(c) { return "OC" }

        let southAmerica: Set<String> = [
            "AR", "BO", "BR", "CL", "CO", "EC", "FK", "GF", "GY", "PE", "PY", "SR", "UY", "VE",
        ]
        if southAmerica.contains(c) { return "SA" }

        let northAmerica: Set<String> = [
            "AG", "AI", "AW", "BB", "BM", "BQ", "BS", "BZ", "CA", "CR", "CU", "CW", "DM", "DO", "GD", "GL",
            "GP", "GT", "HN", "HT", "JM", "KN", "KY", "LC", "MF", "MQ", "MS", "MX", "NI", "PA", "PM", "PR",
            "SV", "SX", "TC", "TT", "US", "VC", "VG", "VI",
        ]
        if northAmerica.contains(c) { return "NA" }

        return "EU"
    }
}

import Foundation

/// Maps app models to `PBSportType` / `PBLanguage` numeric values from the Android protobuf enums.
enum RbliveSportLanguage {
    /// `com.rblive.common.proto.common.PBSportType` values.
    static func sportTypeValue(_ sport: Sport) -> Int32 {
        switch sport {
        case .undefined: return 0
        case .football: return 1
        case .basketball: return 2
        case .tennis: return 3
        case .baseball: return 4
        case .golf: return 17
        case .cricket: return 6
        case .moto: return 7
        case .rugby: return 8
        case .amFootball: return 9
        case .aussieRules: return 10
        case .hockey: return 11
        case .badminton: return 12
        case .volleyball: return 13
        case .fighting: return 14
        case .cycling: return 15
        case .handball: return 16
        case .other: return 90
        }
    }

    /// `com.rblive.common.proto.common.PBLanguage` values.
    static func languageValue(_ lang: AppLanguage) -> Int32 {
        switch lang.id {
        case "en": return 0
        case "zh-Hans": return 1
        case "zh-Hant": return 2
        case "es": return 4
        case "pt": return 5
        case "fr": return 6
        case "de": return 7
        case "it": return 8
        case "ru": return 9
        case "ja": return 10
        case "bg": return 14
        case "el": return 15
        case "pl": return 16
        case "ro": return 17
        case "hu": return 19
        case "nl": return 21
        case "ko": return 23
        case "tr": return 24
        case "th": return 29
        case "sr": return 31
        case "id": return 34
        case "vi": return 35
        case "ar": return 36
        case "my": return 41
        case "pt-BR": return 43
        case "km": return 45
        case "ms": return 49
        case "zh-Hant-TW", "zh-Hant_TW": return 50
        default: return 0
        }
    }

    static func sport(from value: Int32) -> Sport {
        switch value {
        case 0: return .undefined
        case 1: return .football
        case 2: return .basketball
        case 3: return .tennis
        case 4: return .baseball
        case 5: return .other // used by some feeds (not in primary enum labels)
        case 6: return .cricket
        case 7: return .moto
        case 8: return .rugby
        case 9: return .amFootball
        case 10: return .aussieRules
        case 11: return .hockey
        case 12: return .badminton
        case 13: return .volleyball
        case 14: return .fighting
        case 15: return .cycling
        case 16: return .handball
        case 17: return .golf
        case 18, 19, 20: return .other
        case 90: return .other
        default: return .other
        }
    }

    /// Sports shown as their own primary header tabs (excluding All / Others).
    static let primaryExclusiveSports: Set<Sport> = [.football, .basketball, .tennis]

    /// Primary "Others" tab: API type 90 + every sport that is not football/basketball/tennis.
    static func belongsInOthersTab(_ sport: Sport) -> Bool {
        if sport == .other || sport == .undefined { return sport == .other }
        return !primaryExclusiveSports.contains(sport)
    }
}

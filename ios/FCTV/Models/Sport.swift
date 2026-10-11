import SwiftUI

/// Mirrors `PBSportType` from the Android app's proto definitions.
enum Sport: String, CaseIterable, Identifiable, Hashable {
    case undefined
    case football
    case basketball
    case tennis
    case golf
    case moto
    case other
    case amFootball
    case rugby
    case aussieRules
    case cricket
    case hockey
    case badminton
    case baseball
    case volleyball
    case fighting
    case cycling
    case handball

    var id: String { rawValue }

    /// Localized title key used by `String(localized:)`.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .undefined: return "All"
        case .football: return "Football"
        case .basketball: return "Basketball"
        case .tennis: return "Tennis"
        case .golf: return "Golf"
        case .moto: return "Motorsport"
        case .other: return "Others"
        case .amFootball: return "AM. Football"
        case .rugby: return "Rugby"
        case .aussieRules: return "Aussie rules"
        case .cricket: return "Cricket"
        case .hockey: return "Hockey"
        case .badminton: return "Badminton"
        case .baseball: return "Baseball"
        case .volleyball: return "Volleyball"
        case .fighting: return "Fighting"
        case .cycling: return "Cycling"
        case .handball: return "Handball"
        }
    }

    /// SF Symbol used in tabs and the "More" sheet.
    var symbol: String {
        switch self {
        case .undefined: return "square.grid.2x2.fill"
        case .football: return "soccerball"
        case .basketball: return "basketball.fill"
        case .tennis: return "tennis.racket"
        case .golf: return "figure.golf"
        case .moto: return "figure.outdoor.cycle"
        case .other: return "ellipsis.circle.fill"
        case .amFootball: return "football.fill"
        case .rugby: return "rugbyball.fill"
        case .aussieRules: return "rugbyball"
        case .cricket: return "cricket.ball.fill"
        case .hockey: return "hockey.puck.fill"
        case .badminton: return "figure.badminton"
        case .baseball: return "baseball.fill"
        case .volleyball: return "volleyball.fill"
        case .fighting: return "figure.boxing"
        case .cycling: return "bicycle"
        case .handball: return "figure.handball"
        }
    }

    /// Primary tabs displayed on the home header. The remaining sports live in the More sheet.
    static let primaryTabs: [Sport] = [.undefined, .football, .basketball, .tennis, .other]

    /// Full sport list (excluding `undefined`/All), used by the More sheet.
    static let allSports: [Sport] = [
        .football, .basketball, .tennis, .golf, .amFootball, .rugby, .aussieRules,
        .cricket, .hockey, .badminton, .baseball, .volleyball, .fighting,
        .cycling, .handball, .moto, .other,
    ]
}

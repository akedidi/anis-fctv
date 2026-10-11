import Foundation

/// Mirrors `PBMatchStatus` for the relevant cases shown in the UI.
enum MatchStatus: String, Codable, Hashable {
    case scheduled
    case coming
    case firstHalf
    case halfTime
    case secondHalf
    case overtime
    case penalty
    case extraTime
    case finished

    /// Whether the match is currently in play (not scheduled / not finished).
    var isLive: Bool {
        switch self {
        case .firstHalf, .halfTime, .secondHalf, .overtime, .penalty, .extraTime:
            return true
        case .coming, .scheduled, .finished:
            return false
        }
    }

    var isFinished: Bool { self == .finished }

    /// Compact label displayed next to live time (HT / ET / PEN / FT).
    var compactLabel: String {
        switch self {
        case .halfTime: return "HT"
        case .extraTime, .overtime: return "ET"
        case .penalty: return "PEN"
        case .finished: return "FT"
        default: return ""
        }
    }
}

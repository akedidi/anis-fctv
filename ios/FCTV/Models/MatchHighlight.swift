import Foundation

/// A timeline row on the match detail Overview (goals / cards / status).
/// Prefer `/api/match/event` history; score-diff polling is a fallback while the page stays open.
nonisolated struct MatchHighlight: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case goal
        case status
        case info
    }

    let id: String
    let minute: String
    let text: String
    let kind: Kind

    nonisolated init(
        id: String = UUID().uuidString,
        minute: String,
        text: String,
        kind: Kind = .info
    ) {
        self.id = id
        self.minute = minute
        self.text = text
        self.kind = kind
    }
}

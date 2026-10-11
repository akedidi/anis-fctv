import Foundation

/// Fetches schedules, match detail, and resolves playback URLs from the same protobuf
/// HTTP APIs as the Android `rblive` client (`apis-data*.cfd`).
@MainActor
final class MatchService {
    static let shared = MatchService()

    private init() {}

    /// Full list for the home screen (all sports when `sport == .undefined`).
    func fetchMatches(sport: Sport, language: AppLanguage, isActivated: Bool) async throws -> [LiveMatch] {
        if UITestingConfiguration.isEventFlowUITest {
            try await Task.sleep(nanoseconds: 120_000_000)
            let all = MatchServiceUITestSeed.matches
            guard sport != .undefined else { return all }
            return all.filter { $0.sport == sport }
        }
        guard isActivated else { return [] }
        return try await RbliveMatchRepository.fetchLiveMatches(language: language, sport: sport)
    }

    func matchCounts(language: AppLanguage, isActivated: Bool) async -> [Sport: Int] {
        if UITestingConfiguration.isEventFlowUITest {
            let all = MatchServiceUITestSeed.matches
            var counts: [Sport: Int] = [:]
            for sport in Sport.allSports {
                counts[sport] = all.filter { $0.sport == sport }.count
            }
            return counts
        }
        guard isActivated else {
            return Dictionary(uniqueKeysWithValues: Sport.allSports.map { ($0, 0) })
        }
        guard let all = try? await RbliveMatchRepository.fetchLiveMatches(language: language, sport: .undefined) else {
            return Dictionary(uniqueKeysWithValues: Sport.allSports.map { ($0, 0) })
        }
        var counts: [Sport: Int] = [:]
        for sport in Sport.allSports {
            counts[sport] = all.filter { row in
                if sport == .golf {
                    return row.matchesGolfSectionHeuristic() || row.sport == .golf
                }
                if sport == .other {
                    return RbliveSportLanguage.belongsInOthersTab(row.sport)
                }
                return row.sport == sport
            }.count
        }
        return counts
    }

    /// Loads a single match from the backend using the numeric id embedded in an `rbtv77`-style path.
    func fetchMatch(slugURL: String, language: AppLanguage, isActivated: Bool) async throws -> LiveMatch? {
        guard isActivated, let id = Self.matchIDUInt64(fromSlugURL: slugURL) else { return nil }
        let sport = Self.sportFromSlugPath(slugURL)
        return try await RbliveMatchRepository.fetchMatchDetail(matchId: id, sport: sport, language: language)
    }

    /// Refreshes streams and labels from `/api/match/detail` for a row already returned by the live list.
    func fetchMatchDetail(match: LiveMatch, language: AppLanguage, isActivated: Bool) async throws -> LiveMatch? {
        guard isActivated, let id = UInt64(match.id) else { return nil }
        return try await RbliveMatchRepository.fetchMatchDetail(matchId: id, sport: match.sport, language: language)
    }

    /// Loads `/api/match/detail` when you only know the numeric match id and sport (e.g. `2163266` + tennis).
    func fetchMatchDetail(matchId: UInt64, sport: Sport, language: AppLanguage, isActivated: Bool) async throws -> LiveMatch? {
        guard isActivated else { return nil }
        return try await RbliveMatchRepository.fetchMatchDetail(matchId: matchId, sport: sport, language: language)
    }

    /// Starting XI + bench from `/api/match/lineup`.
    func fetchMatchLineup(match: LiveMatch, language: AppLanguage, isActivated: Bool) async throws -> MatchLineup? {
        guard isActivated, let id = UInt64(match.id) else { return nil }
        return try await RbliveMatchRepository.fetchMatchLineup(matchId: id, sport: match.sport, language: language)
    }

    /// Full match timeline from `/api/match/event` (past + live events).
    func fetchMatchEvents(match: LiveMatch, language: AppLanguage, isActivated: Bool) async throws -> [MatchHighlight]? {
        guard isActivated, let id = UInt64(match.id) else { return nil }
        return try await RbliveMatchRepository.fetchMatchEvents(matchId: id, sport: match.sport, language: language)
    }

    func resolvePlaybackURL(match: LiveMatch, stream: StreamServer, language: AppLanguage) async throws -> RbliveResolvedPlayback {
        guard let mid = UInt64(match.id) else {
            throw RbliveAPIError.invalidProtobuf("match id")
        }
        // Prefer the proven fctv33-stream-resolver (web on :3000) — same /api/resolve → playableUrl path.
        // Optional streamId lets server switches target a specific source without leaving the resolver path.
        if FCTVStreamResolverClient.isEnabled {
            return try await FCTVStreamResolverClient.resolve(
                matchId: mid,
                sport: match.sport,
                streamId: stream.backendStreamId
            )
        }
        return try await RbliveMatchRepository.resolveStreamPlaybackURL(matchId: mid, sport: match.sport, stream: stream, language: language)
    }

    /// Extracts the trailing numeric segment of the league slug (e.g. `2164101` in `…-league-2164101`).
    nonisolated static func matchID(fromSlugURL raw: String) -> String? {
        guard let u = matchIDUInt64(fromSlugURL: raw) else { return nil }
        return String(u)
    }

    /// Path segments used for slug parsing (`/fr/football/...` or full `https://host/fr/football/...`).
    nonisolated static func pathComponentsForSlug(_ raw: String) -> [String] {
        if let u = URL(string: raw), let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" {
            return u.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        }
        let withoutQuery = raw.split(separator: "?").first.map(String.init) ?? raw
        return withoutQuery.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    nonisolated static func matchIDUInt64(fromSlugURL raw: String) -> UInt64? {
        let parts = pathComponentsForSlug(raw)
        guard parts.count >= 2 else { return nil }
        let leagueSlug = parts[parts.count - 2]
        guard let dash = leagueSlug.lastIndex(of: "-") else { return nil }
        let suffix = leagueSlug[leagueSlug.index(after: dash)...]
        guard suffix.allSatisfy(\.isNumber), let v = UInt64(suffix) else { return nil }
        return v
    }

    nonisolated static func sportFromSlugPath(_ raw: String) -> Sport {
        let parts = pathComponentsForSlug(raw)
        for p in parts {
            switch p.lowercased() {
            case "football", "soccer": return .football
            case "basketball": return .basketball
            case "tennis": return .tennis
            case "golf": return .golf
            case "volleyball": return .volleyball
            case "hockey", "ice-hockey": return .hockey
            case "baseball": return .baseball
            case "handball": return .handball
            case "badminton": return .badminton
            case "cricket": return .cricket
            case "rugby": return .rugby
            case "mma", "fighting": return .fighting
            case "cycling": return .cycling
            case "motorsport", "moto": return .moto
            default: continue
            }
        }
        return .undefined
    }
}

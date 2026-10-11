import Foundation

/// A single competitor in a match (team or solo player).
nonisolated struct Contender: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Optional remote logo URL.
    let logoURL: URL?
    /// Optional flag emoji (used as a fallback when no logo is available).
    let flag: String?

    nonisolated init(id: String = UUID().uuidString,
                     name: String,
                     logoURL: URL? = nil,
                     flag: String? = nil) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
        self.flag = flag
    }
}

/// One viewable stream / "server" for a match.
nonisolated struct StreamServer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Secondary label (protobuf `fullName` / field 8–10) when different from `name`.
    let fullName: String
    /// HLS / progressive URL once `/api/stream/detail` has been resolved (may be nil until then).
    let playbackURL: URL?
    let resolution: String
    let language: String
    /// Country / region label for UI (inferred from name or match region).
    let country: String
    /// ISO-3166 alpha-2 when known (for flagcdn).
    let countryCode: String?
    /// Backend stream id (for `/api/stream/detail`).
    let backendStreamId: Int64?
    /// `PBDataStream.original_info` wire bytes (field 100), AES-CBC encrypted `PBDataStreamOriginalInfo`.
    let originalInfoWire: Data?
    /// `PBSourceSiteType` value from the live/detail protobuf.
    let backendSiteType: Int32?

    /// Preferred on-screen channel title (never show bare `Stream 0` when a label exists).
    var displayName: String {
        if let n = Self.usableLabel(name) { return n }
        if let f = Self.usableLabel(fullName) { return f }
        if let sid = backendStreamId, sid != 0 { return "Stream \(sid)" }
        return "Live stream"
    }

    /// True when the live/detail API gave a real channel label (not a placeholder).
    var hasReliableChannelName: Bool {
        Self.usableLabel(name) != nil || Self.usableLabel(fullName) != nil
    }

    private static func usableLabel(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("$") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "Success" || s == "OK" { return nil }
        if s.range(of: #"^Stream\s*\d*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        if s.localizedCaseInsensitiveCompare("Live stream") == .orderedSame { return nil }
        return s
    }

    nonisolated init(
        id: String = UUID().uuidString,
        name: String,
        fullName: String = "",
        playbackURL: URL? = nil,
        resolution: String = "",
        language: String = "",
        country: String = "",
        countryCode: String? = nil,
        backendStreamId: Int64? = nil,
        originalInfoWire: Data? = nil,
        backendSiteType: Int32? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.playbackURL = playbackURL
        self.resolution = resolution
        self.language = language
        self.country = country
        self.countryCode = countryCode
        self.backendStreamId = backendStreamId
        self.originalInfoWire = originalInfoWire
        self.backendSiteType = backendSiteType
    }
}

/// One player row from `/api/match/lineup` (`PBDataMatchLineup` + nested `PBDataPlayer`).
nonisolated struct MatchLineupPlayer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Shirt number string when present.
    let number: String?
    /// Short position label (`GK`, `DEF`, `MID`, `FWD`).
    let positionLabel: String
    let positionOrder: Int
    /// `PAT_FIRST` (1) vs substitute / bench (`PAT_SUBSTITUTE` = 2).
    let isStarter: Bool
}

/// Home / away squads for the Lineups tab.
nonisolated struct MatchLineup: Hashable, Sendable {
    let home: [MatchLineupPlayer]
    let away: [MatchLineupPlayer]

    var homeStarters: [MatchLineupPlayer] { home.filter(\.isStarter).sorted { $0.positionOrder < $1.positionOrder } }
    var awayStarters: [MatchLineupPlayer] { away.filter(\.isStarter).sorted { $0.positionOrder < $1.positionOrder } }
}

/// A live or scheduled match displayed on the home list and detail page.
nonisolated struct LiveMatch: Identifiable, Hashable, Sendable {
    let id: String
    let sport: Sport
    let leagueName: String
    /// Remote league / competition logo when present in protobuf.
    let leagueLogoURL: URL?
    /// Country / region flag emoji for the competition (fallback when no logo).
    let leagueFlag: String?
    let region: String
    let contenders: [Contender]
    let homeScore: Int?
    let awayScore: Int?
    let status: MatchStatus
    let startDate: Date
    /// "12'", "HT", "85+", "FT" etc. (formatted live clock for football).
    let liveClock: String?
    let hot: Bool
    let streams: [StreamServer]

    /// Was the match scheduled for today (used to choose date vs. time formatter).
    var isToday: Bool {
        Calendar.current.isDateInToday(startDate)
    }

    /// Calendar day when the kickoff is not today (`10 Oct`). Today: unused (time alone).
    var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "dd MMM"
        return f.string(from: startDate)
    }

    /// Kickoff clock (`18:30`) from `matchDate` (protobuf field 3).
    var timeLabel: String {
        startDate.formatted(date: .omitted, time: .shortened)
    }

    var hasStream: Bool { !streams.isEmpty && status != .scheduled }

    /// Contenders with a real display name (empty / whitespace placeholders ignored).
    var meaningfulContenders: [Contender] {
        contenders.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Classic home/away (or A vs B) layout when two named sides exist.
    /// False for court feeds, solo events, or titles with a single participant.
    var isVersusLayout: Bool {
        meaningfulContenders.count >= 2
    }

    var displayName: String {
        let sides = meaningfulContenders
        if sides.count >= 2 {
            return "\(sides[0].name) vs \(sides[1].name)"
        }
        if let only = sides.first { return only.name }
        let league = leagueName.trimmingCharacters(in: .whitespacesAndNewlines)
        return league.isEmpty ? "Live event" : league
    }

    /// Major golf feeds are sometimes emitted with `PBSportType` mapped to `other`; reuse the same hints for the golf home section and live fetch.
    nonisolated func matchesGolfSectionHeuristic() -> Bool {
        if sport == .golf { return true }
        let blob = ([leagueName, displayName] + contenders.map(\.name))
            .joined(separator: " ")
            .lowercased()
        let needles = [
            "pga", "liv golf", "european tour", "dp world tour", "dp world",
            "fedex cup", "ryder cup", "solheim", "players championship",
            "arnold palmer", "masters tournament",
        ]
        if needles.contains(where: { blob.contains($0) }) { return true }
        return blob.contains("golf") && (blob.contains("tour") || blob.contains("championship") || blob.contains("open"))
    }
}

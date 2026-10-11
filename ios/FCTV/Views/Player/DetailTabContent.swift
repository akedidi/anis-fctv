import SwiftUI

/// Routes the currently selected `DetailTab` to its content.
struct DetailTabContent: View {
    let tab: DetailTab
    let match: LiveMatch
    let highlights: [MatchHighlight]

    var body: some View {
        switch tab {
        case .overview: OverviewTab(match: match, highlights: highlights)
        case .lineups: LineupsTab(match: match)
        case .stats: StatsTab(match: match)
        case .h2h: H2HTab(match: match)
        }
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    let match: LiveMatch
    let highlights: [MatchHighlight]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            sectionHeader("Match info")
            infoCard {
                infoRow(icon: "trophy.fill", title: "Competition", value: displayOrDash(match.leagueName))
                infoRow(icon: "calendar", title: "Date", value: dateString)
                infoRow(icon: "mappin.and.ellipse", title: "Region", value: displayOrDash(match.region))
                infoRow(icon: "tv", title: "Streams", value: "\(match.streams.count) server\(match.streams.count == 1 ? "" : "s")")
                if let clock = match.liveClock {
                    infoRow(icon: "clock.fill", title: "Clock", value: clock)
                }
            }

            sectionHeader("Score")
            scoreCard

            sectionHeader("Highlights")
            highlightsCard
        }
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: match.startDate)
    }

    @ViewBuilder
    private var scoreCard: some View {
        Group {
            if match.isVersusLayout {
                versusScoreCard
            } else {
                singleScoreCard
            }
        }
        .padding(Theme.Spacing.m)
        .cardSurface()
    }

    /// Vertical team columns so long names wrap instead of truncating into “…”.
    private var versusScoreCard: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s) {
            scoreTeamColumn(at: 0)
            VStack(spacing: 6) {
                Text(scoreCenterLabel)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(scoreCenterColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(scoreDigits)
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(minWidth: 88, maxWidth: 110)
            scoreTeamColumn(at: 1)
        }
    }

    private var singleScoreCard: some View {
        VStack(spacing: 10) {
            if let side = match.meaningfulContenders.first {
                ContenderLogo(contender: side, size: 40)
                Text(side.name)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(match.displayName)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Text(scoreCenterLabel)
                .font(.caption.weight(.heavy))
                .foregroundStyle(scoreCenterColor)
            if match.homeScore != nil || match.awayScore != nil {
                Text(scoreDigits)
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scoreTeamColumn(at index: Int) -> some View {
        let sides = match.meaningfulContenders
        return VStack(spacing: 8) {
            if sides.indices.contains(index) {
                let c = sides[index]
                ContenderLogo(contender: c, size: 40)
                Text(c.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var scoreDigits: String {
        let h = match.homeScore.map(String.init) ?? "—"
        let a = match.awayScore.map(String.init) ?? "—"
        return "\(h) - \(a)"
    }

    private var scoreCenterLabel: String {
        if match.status.isFinished { return "FT" }
        if let clock = match.liveClock, !clock.isEmpty { return clock }
        if match.status.isLive { return "LIVE" }
        return match.timeLabel
    }

    private var scoreCenterColor: Color {
        if match.status.isFinished { return Theme.Colors.textTertiary }
        if match.liveClock != nil { return Theme.Colors.matchClock }
        if match.status.isLive { return Theme.Colors.live }
        return Theme.Colors.textSecondary
    }

    private var highlightsCard: some View {
        Group {
            if highlights.isEmpty {
                Text("No timeline events for this match yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
                    .cardSurface()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(highlights) { row in
                        highlightRow(row)
                    }
                }
                .padding(Theme.Spacing.m)
                .cardSurface()
            }
        }
    }

    private func highlightRow(_ row: MatchHighlight) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text(row.minute.isEmpty ? "—" : row.minute)
                .font(.caption.weight(.heavy))
                .foregroundStyle(highlightAccent(row.kind))
                .frame(width: 40, alignment: .leading)
            Text(row.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("player.highlight.\(row.id)")
    }

    private func highlightAccent(_ kind: MatchHighlight.Kind) -> Color {
        switch kind {
        case .goal: return Theme.Colors.accent
        case .status: return Theme.Colors.matchClock
        case .info: return Theme.Colors.textSecondary
        }
    }
}

// MARK: - Lineups

private struct LineupsTab: View {
    let match: LiveMatch
    @Environment(AppState.self) private var appState

    @State private var lineup: MatchLineup?
    @State private var loadFailed = false
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            sectionHeader("Starting XI")
            if isLoading {
                ProgressView()
                    .tint(Theme.Colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.l)
            } else if let lineup, !lineup.homeStarters.isEmpty || !lineup.awayStarters.isEmpty {
                ForEach(0 ..< 2, id: \.self) { idx in
                    if match.contenders.indices.contains(idx) {
                        let c = match.contenders[idx]
                        let players = idx == 0 ? lineup.homeStarters : lineup.awayStarters
                        teamLineup(c: c, players: players)
                    }
                }
            } else {
                Text(loadFailed ? "Lineups unavailable for this match." : "Lineups not announced yet.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
                    .cardSurface()
            }
        }
        .task(id: match.id) {
            await loadLineup()
        }
    }

    private func loadLineup() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            lineup = try await MatchService.shared.fetchMatchLineup(
                match: match,
                language: appState.language,
                isActivated: appState.isActivated
            )
        } catch {
            loadFailed = true
            lineup = nil
        }
    }

    private func teamLineup(c: Contender, players: [MatchLineupPlayer]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ContenderLogo(contender: c, size: 24)
                Text(c.name).font(.headline).foregroundStyle(.white)
                    .lineLimit(2)
            }
            if players.isEmpty {
                Text("Starting XI not available")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                ForEach(players) { player in
                    HStack {
                        Text(player.number ?? "—")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Theme.Colors.accent)
                            .frame(width: 22, alignment: .trailing)
                        Text(player.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text(player.positionLabel)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
        }
        .padding(Theme.Spacing.m)
        .cardSurface()
    }
}

// MARK: - Stats

private struct StatsTab: View {
    let match: LiveMatch

    private let stats: [(String, Double, Double)] = [
        ("Possession", 0.58, 0.42),
        ("Shots", 12, 8),
        ("Shots on target", 5, 3),
        ("Corners", 6, 4),
        ("Fouls", 9, 11),
        ("Yellow cards", 2, 3),
        ("Offsides", 3, 1),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            sectionHeader("Match stats")
                .accessibilityIdentifier("player.stats.heading")
            VStack(spacing: 14) {
                ForEach(stats.indices, id: \.self) { i in
                    statRow(title: stats[i].0, home: stats[i].1, away: stats[i].2)
                }
            }
            .padding(Theme.Spacing.m)
            .cardSurface()
        }
    }

    private func statRow(title: String, home: Double, away: Double) -> some View {
        let total = max(home + away, 1)
        let homeRatio = home / total
        return VStack(spacing: 4) {
            HStack {
                Text(format(home))
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                Spacer()
                Text(title).font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(format(away))
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Colors.accent)
                            .frame(width: geo.size.width * homeRatio)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Colors.success)
                            .frame(width: geo.size.width * (1 - homeRatio))
                    }
                }
            }
            .frame(height: 6)
        }
    }

    private func format(_ value: Double) -> String {
        if value > 0, value < 1 { return "\(Int(value * 100))%" }
        return "\(Int(value))"
    }
}

// MARK: - H2H

private struct H2HTab: View {
    let match: LiveMatch

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            sectionHeader("Head-to-head")
            recordCard
            sectionHeader("Last 5 meetings")
            ForEach(sampleMeetings, id: \.0) { meet in
                meetingRow(date: meet.0, home: meet.1, score: meet.2, away: meet.3)
            }
        }
    }

    private var recordCard: some View {
        HStack {
            statColumn(value: "3", label: "Wins")
            statColumn(value: "1", label: "Draws")
            statColumn(value: "2", label: "Losses")
        }
        .padding(Theme.Spacing.m)
        .cardSurface()
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.Colors.accent)
            Text(label).font(.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sampleMeetings: [(String, String, String, String)] {
        let teamA = match.contenders.first?.name ?? "Home"
        let teamB = match.contenders.dropFirst().first?.name ?? "Away"
        return [
            ("Apr 2025", teamA, "2-1", teamB),
            ("Nov 2024", teamA, "1-1", teamB),
            ("Mar 2024", teamA, "0-2", teamB),
            ("Aug 2023", teamA, "3-1", teamB),
            ("Feb 2023", teamA, "1-0", teamB),
        ]
    }

    private func meetingRow(date: String, home: String, score: String, away: String) -> some View {
        HStack {
            Text(date).font(.caption2).foregroundStyle(Theme.Colors.textTertiary).frame(width: 60, alignment: .leading)
            Text(home).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(2)
            Text(score)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            Text(away).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.Spacing.m)
        .cardSurface()
    }
}

// MARK: - Shared helpers

private func displayOrDash(_ value: String) -> String {
    let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? "—" : t
}

private func sectionHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
        .font(.system(size: 14, weight: .heavy))
        .foregroundStyle(Theme.Colors.textSecondary)
        .textCase(.uppercase)
        .tracking(0.5)
}

private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10, content: content)
        .padding(Theme.Spacing.m)
        .cardSurface()
}

private func infoRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon)
            .foregroundStyle(Theme.Colors.accent)
            .frame(width: 18)
            .padding(.top, 2)
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Colors.textSecondary)
        Spacer(minLength: 8)
        Text(value)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.trailing)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

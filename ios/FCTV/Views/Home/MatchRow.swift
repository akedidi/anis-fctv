import SwiftUI

/// Single match card displayed in the home list.
struct MatchRow: View {
    let match: LiveMatch

    var body: some View {
        VStack(spacing: 0) {
            leagueHeader
            if match.isVersusLayout {
                versusRow
            } else {
                singleEventRow
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Sizing.cornerLarge, style: .continuous)
                .fill(Theme.Colors.surface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Sizing.cornerLarge, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var leagueHeader: some View {
        HStack(spacing: 8) {
            leagueBadge
            Text(match.leagueName.isEmpty ? " " : match.leagueName)
                .lineLimit(1)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            // Compact status only — never a fake green "LIVE" in place of kickoff/minute.
            StatusBadge(match: match)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var leagueBadge: some View {
        Group {
            if let url = match.leagueLogoURL {
                RemoteLogo(url: url, size: 14, cornerRadius: 2)
            } else if let flag = match.leagueFlag {
                Text(flag).font(.system(size: 11))
            } else if let code = CountryHelper.infer(fromStreamName: "", matchRegion: match.region).code,
                      let flagURL = CountryHelper.flagCDNURL(for: code, width: 20) {
                RemoteLogo(url: flagURL, size: 14, cornerRadius: 2)
            } else {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.45))
            }
        }
        .frame(width: 20, height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private var versusRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            timeColumn
            contenderColumn(at: 0, alignment: .leading)
            scoreBlock
            contenderColumn(at: 1, alignment: .trailing)
        }
    }

    private var singleEventRow: some View {
        HStack(spacing: 14) {
            timeColumn

            if let side = match.meaningfulContenders.first {
                ContenderLogo(contender: side, size: Theme.Sizing.teamLogo)
            } else if let url = match.leagueLogoURL {
                RemoteLogo(url: url, size: Theme.Sizing.teamLogo, cornerRadius: Theme.Sizing.teamLogo / 2)
            } else {
                Image(systemName: "sportscourt.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: Theme.Sizing.teamLogo, height: Theme.Sizing.teamLogo)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(match.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let h = match.homeScore, let a = match.awayScore {
                    Text("\(h)-\(a)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Left column: kickoff date/time always, plus server elapsed clock (`76'`) when live.
    private var timeColumn: some View {
        VStack(spacing: 2) {
            if !match.isToday {
                Text(match.dateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
            Text(match.timeLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if match.status == .finished {
                Text("FT")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else if match.status.isLive, let clock = match.liveClock, !clock.isEmpty {
                Text(clock)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.Colors.matchClock)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: 54, alignment: .center)
        .accessibilityLabel(accessibilityTime)
    }

    private var accessibilityTime: String {
        var parts = [match.timeLabel]
        if !match.isToday { parts.insert(match.dateLabel, at: 0) }
        if match.status == .finished {
            parts.append("FT")
        } else if let clock = match.liveClock, match.status.isLive {
            parts.append(clock)
        }
        return parts.joined(separator: ", ")
    }

    private func contenderColumn(at index: Int, alignment: HorizontalAlignment) -> some View {
        let frameAlign: Alignment = alignment == .leading ? .leading : .trailing
        let textAlign: TextAlignment = alignment == .leading ? .leading : .trailing
        let sides = match.meaningfulContenders
        return Group {
            if sides.indices.contains(index) {
                let contender = sides[index]
                VStack(alignment: alignment, spacing: 6) {
                    ContenderLogo(contender: contender, size: Theme.Sizing.teamLogo)
                        .frame(maxWidth: .infinity, alignment: frameAlign)
                    Text(contender.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(textAlign)
                        .frame(maxWidth: .infinity, alignment: frameAlign)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var scoreBlock: some View {
        VStack(spacing: 4) {
            if let home = match.homeScore, let away = match.awayScore {
                Text("\(home)  -  \(away)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(scoreColor)
            } else {
                Text("VS")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(width: 72)
    }

    private var scoreColor: Color {
        match.status == .finished ? Theme.Colors.textSecondary : .white
    }
}

#Preview {
    VStack(spacing: 12) {
        MatchRow(match: MatchServiceUITestSeed.matches[0])
        MatchRow(match: MatchServiceUITestSeed.matches[1])
    }
    .padding()
    .background(Theme.Colors.background)
}

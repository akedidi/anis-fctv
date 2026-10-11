import SwiftUI

/// Header at the top of the player screen showing the league, date, two teams
/// (or a single-event title), the live clock and the score / VS divider.
struct MatchDetailHeader: View {
    let match: LiveMatch
    /// Top inset under status / drag handle (default keeps room for player chrome).
    var topPadding: CGFloat = 52

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack(spacing: 8) {
                Group {
                    if let url = match.leagueLogoURL {
                        RemoteLogo(url: url, size: 14, cornerRadius: 2)
                    } else if let flag = match.leagueFlag {
                        Text(flag).font(.system(size: 11))
                    } else {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.45))
                    }
                }
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                )
                Text(match.leagueName.isEmpty ? "—" : match.leagueName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Text(dateLabel)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)

            if match.isVersusLayout {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    teamColumn(at: 0)
                    centerColumn
                    teamColumn(at: 1)
                }
                .padding(.top, 4)
            } else {
                singleEventBlock
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, topPadding)
        .padding(.bottom, Theme.Spacing.m)
        .background(
            LinearGradient(
                colors: [Theme.Colors.headerGradientStart, Theme.Colors.headerGradientEnd],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var singleEventBlock: some View {
        VStack(spacing: 10) {
            if let side = match.meaningfulContenders.first {
                ContenderLogo(contender: side, size: 64)
            } else if let url = match.leagueLogoURL {
                RemoteLogo(url: url, size: 64, cornerRadius: 16)
            } else {
                Image(systemName: "sportscourt.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            Text(match.displayName)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            statusChip
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusChip: some View {
        if match.status.isLive {
            HStack(spacing: 4) {
                LiveDot()
                Text(match.liveClock ?? match.timeLabel)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.Colors.live)
            }
        } else if match.status.isFinished {
            Text("FT")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.Colors.textTertiary)
        } else {
            Text(match.timeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func teamColumn(at index: Int) -> some View {
        let sides = match.meaningfulContenders
        return Group {
            if sides.indices.contains(index) {
                let c = sides[index]
                VStack(spacing: 6) {
                    ContenderLogo(contender: c, size: 52)
                    Text(c.name)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 6) {
            if match.status.isLive, let clock = match.liveClock {
                Text(clock)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.Colors.matchClock)
            } else if match.status.isFinished {
                Text("FT")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                Text(match.timeLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if let h = match.homeScore, let a = match.awayScore {
                Text("\(h) - \(a)")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.white)
            } else {
                Text("VS")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(.white)
            }
            if match.status.isLive {
                HStack(spacing: 4) {
                    LiveDot()
                    Text("LIVE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.Colors.live)
                }
            }
        }
        .frame(width: 110)
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM • HH:mm"
        return f.string(from: match.startDate)
    }
}

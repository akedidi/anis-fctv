import SwiftUI

/// Compact status chip in the league header — never replaces kickoff / match minute.
struct StatusBadge: View {
    let match: LiveMatch

    var body: some View {
        Group {
            switch match.status {
            case .scheduled:
                EmptyView()
            case .finished:
                Text("FT")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.Colors.textTertiary)
            default:
                // Subtle live mark only (no green/red "LIVE" text stealing the clock).
                LiveDot()
                    .accessibilityLabel("Live")
            }
        }
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        switch match.status {
        case .scheduled: return "Scheduled \(match.timeLabel)"
        case .finished: return "Full time"
        default: return "Live\(match.liveClock.map { ", \($0)" } ?? "")"
        }
    }
}

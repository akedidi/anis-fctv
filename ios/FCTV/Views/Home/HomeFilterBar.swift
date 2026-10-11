import SwiftUI

/// Pill row directly above the match list: All / Live (with count) / Finished.
struct HomeFilterBar: View {
    let selected: HomeFilter
    let liveCount: Int
    let onSelect: (HomeFilter) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            ForEach(HomeFilter.allCases) { filter in
                Button {
                    onSelect(filter)
                } label: {
                    HStack(spacing: 6) {
                        if filter == .live {
                            LiveDot()
                        }
                        Text(filter.title)
                            .font(.system(size: 14, weight: .semibold))
                        if filter == .live, liveCount > 0 {
                            Text("\(liveCount)")
                                .font(.system(size: 11, weight: .heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        selected == filter
                                        ? Color.black.opacity(0.15)
                                        : Theme.Colors.live.opacity(0.85)
                                    )
                                )
                                .foregroundStyle(.white)
                        }
                    }
                    .chipStyle(selected: selected == filter)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

import SwiftUI

/// Horizontal tab bar shown beneath the player (Overview / Lineups / Stats / H2H).
struct DetailTabBar: View {
    let selected: DetailTab
    let onSelect: (DetailTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 6) {
                        Text(tab.title)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(tab == selected ? Theme.Colors.accent : Theme.Colors.textMuted)
                        Rectangle()
                            .fill(tab == selected ? Theme.Colors.accent : Color.clear)
                            .frame(height: 2)
                            .padding(.horizontal, 18)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.tab.\(tab.rawValue)")
                .animation(.easeOut(duration: 0.15), value: selected)
            }
        }
    }
}

import SwiftUI

/// Bottom sheet listing all sports for filtering (mirrors `dialog_more_sport`).
struct MoreSportsSheet: View {
    let selectedSport: Sport
    let onSelect: (Sport) -> Void

    @Environment(AppState.self) private var appState
    @State private var counts: [Sport: Int] = [:]

    private let columns: [GridItem] = Array(repeating: .init(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Sports")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.top, Theme.Spacing.m)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Sport.allSports) { sport in
                        Button {
                            onSelect(sport)
                        } label: {
                            sportTile(sport)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.Colors.surface)
        .task { await refreshCounts() }
        .onChange(of: appState.language) { _, _ in Task { await refreshCounts() } }
        .onChange(of: appState.isActivated) { _, _ in Task { await refreshCounts() } }
    }

    private func refreshCounts() async {
        counts = await MatchService.shared.matchCounts(language: appState.language, isActivated: appState.isActivated)
    }

    private func sportTile(_ sport: Sport) -> some View {
        let count = counts[sport] ?? 0
        let selected = sport == selectedSport
        return VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(selected ? Theme.Colors.accent : Color.white.opacity(0.08))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: sport.symbol)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(selected ? .black : .white)
                    }
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Colors.live))
                        .foregroundStyle(.white)
                        .offset(x: 6, y: -6)
                }
            }
            Text(sport.localizedTitle)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Sizing.cornerMedium)
                .stroke(selected ? Theme.Colors.accent : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

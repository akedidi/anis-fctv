import SwiftUI

/// Top of the home screen: branding row + sport tab strip.
struct HomeHeaderView: View {
    let selectedSport: Sport
    let liveCount: Int
    /// Per-sport event counts for red pills (All / Football / … / More) — same as Flutter/web.
    var badgeCountForSport: (Sport) -> Int = { _ in 0 }
    var moreBadgeCount: Int = 0
    let onSelectSport: (Sport) -> Void
    let onShowMoreSports: () -> Void
    let onShowLanguage: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 10) {
            topRow
            tabsStrip
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .background(
            LinearGradient(
                colors: [Theme.Colors.headerGradientStart, Theme.Colors.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text("FCTV33")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(1.2)
            }
            Spacer(minLength: 8)
            Button(action: onShowLanguage) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .semibold))
                    Text(appState.language.nativeName)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change language")

            AirPlayRouteButton()
                .frame(width: 28, height: 28)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .accessibilityIdentifier("home.airPlayButton")
                .accessibilityLabel("AirPlay")
        }
    }

    private var tabsStrip: some View {
        let ancillarySelected = !Sport.primaryTabs.contains(selectedSport)
        return HStack(spacing: 0) {
            ForEach(Sport.primaryTabs) { sport in
                let n = badgeCountForSport(sport)
                SportTab(
                    sport: sport,
                    isSelected: sport == selectedSport,
                    badge: n > 0 ? "\(n)" : nil
                ) {
                    onSelectSport(sport)
                }
            }
            SportTab(
                sport: nil,
                title: "More",
                symbol: "ellipsis",
                isSelected: ancillarySelected,
                badge: moreBadgeCount > 0 ? "\(moreBadgeCount)" : nil,
                action: onShowMoreSports
            )
        }
    }
}

private struct SportTab: View {
    let sport: Sport?
    var title: LocalizedStringKey?
    var symbol: String?
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.Colors.accent : Color.white.opacity(0.1))
                        .frame(width: 44, height: 44)
                    Image(systemName: symbol ?? sport?.symbol ?? "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.Colors.live))
                            .offset(x: 14, y: -14)
                    }
                }
                Text(title ?? sport?.localizedTitle ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

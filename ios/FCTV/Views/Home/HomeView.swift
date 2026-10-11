import SwiftUI

/// Top-level matches list (mirrors `com.rblive.app.ui.home.HomeActivity`).
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackSession.self) private var playbackSession
    @State private var vm = HomeViewModel()
    @State private var selectedMatch: LiveMatch?
    @State private var showMoreSports = false
    @State private var showLanguageSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HomeHeaderView(
                selectedSport: vm.sport,
                liveCount: vm.liveCount,
                badgeCountForSport: { vm.badgeCount(for: $0) },
                moreBadgeCount: vm.moreBadgeCount,
                onSelectSport: { vm.selectSport($0) },
                onShowMoreSports: { showMoreSports = true },
                onShowLanguage: { showLanguageSheet = true }
            )

            // Under sport tabs (streamsports-style), above All / Live / Finished.
            HomeSearchField(
                text: Binding(
                    get: { vm.searchText },
                    set: { vm.setSearchText($0) }
                )
            )
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, 8)
            .padding(.bottom, 4)

            HomeFilterBar(selected: vm.filter, liveCount: vm.liveCount) { newFilter in
                vm.setFilter(newFilter)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, 4)
            .padding(.bottom, 4)

            if let err = vm.errorText {
                Text(err)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.xs)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background.ignoresSafeArea())
        // Reserve bottom space so match rows never sit under the mini-player (streamsports contentInset).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar {
                if let m = playbackSession.match {
                    selectedMatch = m
                    playbackSession.expand()
                }
            }
        }
        // No spring on isActive — animating the mini dock mount fought the surface reparent and blipped audio.
        .task {
            if vm.allMatches.isEmpty {
                await vm.load(language: appState.language, isActivated: appState.isActivated)
            }
            await openLivePlaybackUITestMatchIfNeeded()
            await openAutoMatchByIdIfNeeded()
            await openAutoMatchByNameIfNeeded()
        }
        .onChange(of: appState.language) { _, _ in
            Task { await vm.load(language: appState.language, isActivated: appState.isActivated) }
        }
        .onChange(of: appState.isActivated) { _, _ in
            Task { await vm.load(language: appState.language, isActivated: appState.isActivated) }
        }
        .onChange(of: appState.sessionRecoveryToken) { _, _ in
            // Long background cleared rb-session — reload live list like pull-to-refresh.
            Task {
                fputs("[home] session recovery → API refresh\n", stderr)
                await vm.refresh(language: appState.language, isActivated: appState.isActivated)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("home.root")
        .sheet(isPresented: $showMoreSports) {
            MoreSportsSheet(selectedSport: vm.sport) { sport in
                vm.selectSport(sport)
                showMoreSports = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.surface)
        }
        .sheet(isPresented: $showLanguageSheet) {
            LanguageSheet(selectedID: appState.language.id) { lang in
                appState.language = lang
                showLanguageSheet = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.surface)
        }
        .fullScreenCover(item: $selectedMatch, onDismiss: {
            // Detail kept the video during dismiss; reveal mini only once the cover is gone.
            playbackSession.revealDockAfterDetailDismiss()
        }) { match in
            PlayerView(match: match) { selectedMatch = nil }
        }
    }

    /// Open detail UI immediately; enrich streams in `PlayerView` (no pre-await on `/api/match/detail`).
    private func openMatch(_ summary: LiveMatch) {
        // Opening another event must stop the previous mini-player session immediately.
        playbackSession.prepareForNewEvent(matchId: summary.id)
        selectedMatch = summary
    }

    private func openLivePlaybackUITestMatchIfNeeded() async {
        guard UITestingConfiguration.isLivePlaybackUITest,
              selectedMatch == nil,
              let raw = UITestingConfiguration.livePlaybackTargetURLString
        else { return }
        if let m = try? await MatchService.shared.fetchMatch(slugURL: raw, language: appState.language, isActivated: appState.isActivated) {
            selectedMatch = m
        }
    }

    private func openAutoMatchByIdIfNeeded() async {
        guard selectedMatch == nil, appState.isActivated else { return }
        guard let mid = PlaybackOpenShortcut.autoOpenMatchIdUInt64 else { return }
        if vm.allMatches.isEmpty {
            await vm.load(language: appState.language, isActivated: appState.isActivated)
        }
        let sport: Sport
        if let row = vm.allMatches.first(where: { $0.id == String(mid) }) {
            sport = row.sport
        } else {
            sport = PlaybackOpenShortcut.resolvedSportHint(forMatchId: mid)
        }
        if let m = try? await MatchService.shared.fetchMatchDetail(
            matchId: mid,
            sport: sport,
            language: appState.language,
            isActivated: appState.isActivated
        ) {
            selectedMatch = m
        }
    }

    private func openAutoMatchByNameIfNeeded() async {
        guard selectedMatch == nil,
              let needle = PlaybackOpenShortcut.matchNameSubstring?.lowercased(), !needle.isEmpty,
              appState.isActivated
        else { return }
        if vm.allMatches.isEmpty {
            await vm.load(language: appState.language, isActivated: appState.isActivated)
        }
        func matches(_ m: LiveMatch) -> Bool {
            if m.displayName.lowercased().contains(needle) { return true }
            if m.leagueName.lowercased().contains(needle) { return true }
            return m.contenders.contains { $0.name.lowercased().contains(needle) }
        }
        let pool = vm.allMatches.filter { matches($0) }
        let chosen = pool.first(where: { $0.status.isLive && $0.hasStream })
            ?? pool.first(where: { $0.hasStream })
        guard let summary = chosen else { return }
        if let detailed = try? await MatchService.shared.fetchMatchDetail(
            match: summary,
            language: appState.language,
            isActivated: appState.isActivated
        ) {
            selectedMatch = detailed
        } else {
            selectedMatch = summary
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.allMatches.isEmpty {
            VStack {
                Spacer()
                ProgressView().tint(.white)
                    .scaleEffect(1.3)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if vm.filteredMatches.isEmpty {
                        EmptyStateView(searchActive: !vm.appliedSearchQuery.isEmpty)
                            .frame(minHeight: 320)
                    } else {
                        ForEach(Array(vm.filteredMatches.enumerated()), id: \.element.id) { index, match in
                            Button {
                                openMatch(match)
                            } label: {
                                MatchRow(match: match)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(index == 0 ? "home.matchRow.first" : "home.matchRow.\(match.id)")
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, 2)
                .padding(.bottom, Theme.Spacing.s)
            }
            // Pull-to-refresh must always hit the API. Escape SwiftUI's refresh
            // cancellation (gesture end cancels the task mid-request otherwise).
            .refreshable {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        await vm.refresh(
                            language: appState.language,
                            isActivated: appState.isActivated
                        )
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private struct EmptyStateView: View {
    var searchActive: Bool = false

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Spacer()
            Image(systemName: searchActive ? "magnifyingglass" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(searchActive ? "No results" : "No Data")
                .font(.headline)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(searchActive ? "Try another team, league, or event" : "Pull down to refresh")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    HomeView()
        .environment(AppState())
        .environment(PlaybackSession())
}

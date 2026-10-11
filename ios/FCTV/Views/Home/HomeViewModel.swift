import Foundation
import SwiftUI

/// Mirrors `com.rblive.common.ui.home.HomeViewModel`.
///
/// Drives the sport tab + filter chip selection and exposes the filtered match
/// list to the view layer.
@MainActor
@Observable
final class HomeViewModel {
    var sport: Sport = .undefined
    /// Status chips default to All (not Live-only).
    var filter: HomeFilter = .all
    /// Raw text from the search field (updates as the user types).
    var searchText: String = ""
    /// Debounced query actually applied to `filteredMatches`.
    private(set) var appliedSearchQuery: String = ""
    var allMatches: [LiveMatch] = []
    var isLoading: Bool = true
    /// True only during pull-to-refresh (keeps the list visible; system spinner handles UI).
    var isRefreshing: Bool = false
    var liveCount: Int = 0
    var errorText: String?

    /// Sports shown as primary header tabs (badges); everything else rolls into "More".
    private static let primaryBadgeSports: Set<Sport> = [.football, .basketball, .tennis, .other]

    private let service = MatchService.shared
    private var searchDebounceTask: Task<Void, Never>?

    /// Red pill on a primary sport tab — same logic as Flutter/web (`badgeForSport`).
    func badgeCount(for sport: Sport) -> Int {
        switch sport {
        case .undefined:
            return allMatches.count
        case .other:
            return allMatches.filter { RbliveSportLanguage.belongsInOthersTab($0.sport) }.count
        case .golf:
            return allMatches.filter { $0.matchesGolfSectionHeuristic() || $0.sport == .golf }.count
        default:
            return allMatches.filter { $0.sport == sport }.count
        }
    }

    /// Red pill on the More tab — events in sports that are not primary tabs.
    var moreBadgeCount: Int {
        allMatches.filter { !Self.primaryBadgeSports.contains($0.sport) }.count
    }

    init() {
        // Optional smoke: `FCTV_HOME_SPORT=football` lands on a sport with field-150 clocks.
        if let raw = ProcessInfo.processInfo.environment["FCTV_HOME_SPORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let s = Sport(rawValue: raw) {
            sport = s
        }
    }

    /// Mirrors `convertData` + `filterData`: applies the user's current sport
    /// and filter to the loaded match list, sorting live → upcoming → finished.
    /// Search is an additional local filter on top of sport + All/Live/Finished.
    var filteredMatches: [LiveMatch] {
        var result: [LiveMatch]
        switch sport {
        case .undefined:
            result = allMatches
        case .other:
            // Primary "Others" = not football / basketball / tennis (plus sportType 90).
            result = allMatches.filter { RbliveSportLanguage.belongsInOthersTab($0.sport) }
        default:
            result = allMatches.filter { row in
                if sport == .golf { return row.matchesGolfSectionHeuristic() }
                return row.sport == sport
            }
        }
        switch filter {
        case .all:
            break
        case .live:
            // In-play only — do not include upcoming (scheduled) fixtures.
            result = result.filter { $0.status.isLive && !$0.status.isFinished }
        case .finished:
            result = result.filter { $0.status.isFinished }
        }
        let needle = appliedSearchQuery
        if !needle.isEmpty {
            result = result.filter { Self.matchesSearch($0, needle: needle) }
        }
        return result.sorted(by: orderingPredicate)
    }

    func setSearchText(_ text: String) {
        searchText = text
        searchDebounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear applies immediately; typing gets a light debounce.
        if trimmed.isEmpty {
            appliedSearchQuery = ""
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            appliedSearchQuery = trimmed
        }
    }

    /// Case-insensitive match against event title, league, region, and contenders.
    static func matchesSearch(_ match: LiveMatch, needle: String) -> Bool {
        let n = needle.lowercased()
        guard !n.isEmpty else { return true }
        if match.displayName.lowercased().contains(n) { return true }
        if match.leagueName.lowercased().contains(n) { return true }
        if match.region.lowercased().contains(n) { return true }
        if match.contenders.contains(where: { $0.name.lowercased().contains(n) }) { return true }
        return false
    }

    /// Live → in-progress → scheduled → finished, then by start date.
    private func orderingPredicate(_ a: LiveMatch, _ b: LiveMatch) -> Bool {
        if a.status.isLive != b.status.isLive { return a.status.isLive }
        if a.hot != b.hot { return a.hot }
        return a.startDate < b.startDate
    }

    func load(language: AppLanguage, isActivated: Bool) async {
        await fetch(language: language, isActivated: isActivated, mode: .initial)
    }

    /// Pull-to-refresh: always re-calls `/api/common/bs` + `/api/match/live`.
    /// Keeps sport / filter selection; does not blank the list on failure/cancel.
    func refresh(language: AppLanguage, isActivated: Bool) async {
        fputs("[home] pull-to-refresh → API reload\n", stderr)
        await fetch(language: language, isActivated: isActivated, mode: .pullToRefresh)
    }

    private enum FetchMode { case initial, pullToRefresh }

    private func fetch(language: AppLanguage, isActivated: Bool, mode: FetchMode) async {
        switch mode {
        case .initial:
            isLoading = true
        case .pullToRefresh:
            isRefreshing = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }
        errorText = nil

        // DEBUG skip-activation must still fetch; never treat as inactive for home reload.
        let canFetch = isActivated || UITestingConfiguration.skipActivationGate
        guard canFetch else {
            if mode == .initial || allMatches.isEmpty {
                allMatches = []
                liveCount = 0
            }
            errorText = "Activation required"
            return
        }

        do {
            // Always fetch the full list; local `sport` / `filter` re-apply via `filteredMatches`.
            let matches = try await service.fetchMatches(
                sport: .undefined,
                language: language,
                isActivated: true
            )
            // Pull-to-refresh: never wipe a good list with an empty API response.
            if matches.isEmpty, mode == .pullToRefresh, !allMatches.isEmpty {
                errorText = "Refresh returned no events — keeping previous list"
                fputs("[home] refresh empty — keeping \(allMatches.count) matches\n", stderr)
                return
            }
            allMatches = matches
            liveCount = matches.filter { $0.status.isLive }.count
            fputs("[home] fetch ok count=\(matches.count) mode=\(mode)\n", stderr)
        } catch is CancellationError {
            // SwiftUI `.refreshable` cancels when the gesture ends — keep previous data.
            fputs("[home] fetch cancelled — keeping \(allMatches.count) matches\n", stderr)
        } catch {
            if mode == .initial || allMatches.isEmpty {
                allMatches = []
                liveCount = 0
            }
            errorText = error.localizedDescription
            fputs("[home] fetch failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func selectSport(_ newSport: Sport) {
        guard newSport != sport else { return }
        sport = newSport
        // Keep status filter (All / Live / Finished); don't force Live.
    }

    func setFilter(_ newFilter: HomeFilter) {
        filter = newFilter
    }
}

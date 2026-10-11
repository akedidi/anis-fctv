import Foundation
import SwiftUI

/// Top-level app navigation flow, mirroring the original Splash → Activation → Home routing.
enum AppRoute: Hashable {
    case splash
    case activation
    case home
}

/// Single source of truth for user preferences and runtime state.
@MainActor
@Observable
final class AppState {
    var route: AppRoute = .splash
    var language: AppLanguage {
        didSet {
            guard !UITestingConfiguration.isEventFlowUITest, !UITestingConfiguration.isLivePlaybackUITest else { return }
            UserDefaults.standard.set(language.id, forKey: Keys.language)
        }
    }
    var isActivated: Bool {
        didSet {
            guard !UITestingConfiguration.isEventFlowUITest, !UITestingConfiguration.isLivePlaybackUITest else { return }
            UserDefaults.standard.set(isActivated, forKey: Keys.activated)
        }
    }
    var favoriteMatchIDs: Set<String> {
        didSet {
            guard !UITestingConfiguration.isEventFlowUITest, !UITestingConfiguration.isLivePlaybackUITest else { return }
            UserDefaults.standard.set(Array(favoriteMatchIDs), forKey: Keys.favorites)
        }
    }
    /// Marquee notice text shown on splash and home; in the original this came
    /// from a backend `NoticeForApp` payload.
    let notice: String = "FCTV33 – live matches everywhere, on every device."

    /// Bumped after long background so Home reloads live data with a fresh session.
    private(set) var sessionRecoveryToken: UInt = 0

    func requestSessionRecoveryRefresh() {
        sessionRecoveryToken &+= 1
    }

    init() {
        let savedLangID = UserDefaults.standard.string(forKey: Keys.language) ?? AppLanguage.default.id
        self.language = AppLanguage.all.first(where: { $0.id == savedLangID }) ?? .default
        self.isActivated = UserDefaults.standard.bool(forKey: Keys.activated)
        let favs = UserDefaults.standard.array(forKey: Keys.favorites) as? [String] ?? []
        self.favoriteMatchIDs = Set(favs)

        if UITestingConfiguration.isEventFlowUITest {
            self.route = .home
            self.isActivated = true
        } else if UITestingConfiguration.isLivePlaybackUITest {
            self.route = .home
            self.isActivated = true
        } else if UITestingConfiguration.skipActivationGate {
            // Activation UI disabled for now (Debug + Release IPA); replace later.
            self.isActivated = true
        }
    }

    func toggleFavorite(_ matchID: String) {
        if favoriteMatchIDs.contains(matchID) {
            favoriteMatchIDs.remove(matchID)
        } else {
            favoriteMatchIDs.insert(matchID)
        }
    }

    func isFavorite(_ matchID: String) -> Bool {
        favoriteMatchIDs.contains(matchID)
    }

    private enum Keys {
        static let language = "fctv.language"
        static let activated = "fctv.activated"
        static let favorites = "fctv.favorites"
    }
}

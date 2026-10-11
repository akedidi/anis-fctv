import SwiftUI

/// Root navigation gate. Drives the Splash → Activation → Home flow based on
/// `AppState.route`, replicating the original Android activity stack.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    /// When the scene last entered `.background` — used to refresh after long idle.
    @State private var backgroundedAt: Date?

    /// Same idea as force-quit: drop stale in-memory session after a long suspension.
    private static let idleRefreshThreshold: TimeInterval = 120

    var body: some View {
        ZStack {
            switch appState.route {
            case .splash:
                SplashView()
                    .transition(.opacity)
            case .activation:
                ActivationView()
                    .transition(.opacity)
            case .home:
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.route)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = .now
        case .active:
            guard let started = backgroundedAt else { return }
            backgroundedAt = nil
            let idle = Date().timeIntervalSince(started)
            guard idle >= Self.idleRefreshThreshold else { return }
            fputs("[app] resume after \(Int(idle))s idle → clear session + refresh\n", stderr)
            Task {
                await RbliveHTTPClient.shared.clearSession()
                await MainActor.run {
                    RbliveLocalHlsServer.shared.restart()
                    appState.requestSessionRecoveryRefresh()
                }
            }
        default:
            break
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(PlaybackSession())
}

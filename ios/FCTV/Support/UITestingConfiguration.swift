import Foundation

/// Launch arguments consumed by the app during UI tests (`XCUIApplication.launchArguments`).
enum UITestingConfiguration {
    /// Skip splash/activation and land on home with mock data (deterministic E2E).
    static let eventFlowArgument = "--uitesting-event-flow"

    /// Real network: home + activated, optional deep-link match from `--uitesting-playback-url`.
    static let livePlaybackArgument = "--uitesting-live-playback"

    /// Forces `RbliveHlsInjectEngine.injectEnabled` so segment `_sou` + headers match Android during UI tests.
    static let stinjUITestArgument = "--uitesting-stinj-enabled"

    /// Force-skip activation gate (`--fctv-skip-activation` / `FCTV_SKIP_ACTIVATION=1`).
    static let skipActivationArgument = "--fctv-skip-activation"

    /// Force-show activation even in DEBUG (`--fctv-force-activation` / `FCTV_SKIP_ACTIVATION=0`).
    static let forceActivationArgument = "--fctv-force-activation"

    static var isEventFlowUITest: Bool {
        ProcessInfo.processInfo.arguments.contains(eventFlowArgument)
    }

    static var isLivePlaybackUITest: Bool {
        ProcessInfo.processInfo.arguments.contains(livePlaybackArgument)
    }

    /// Full event URL (e.g. MadPlay77 HTML page); next argument after `--uitesting-playback-url`.
    static var livePlaybackTargetURLString: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--uitesting-playback-url"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// Skip `ActivationView` and treat the package as active.
    /// Default **on** for Debug and Release (IPA included) — activation UI will be replaced later.
    /// To temporarily bring the gate back: `--fctv-force-activation` or `FCTV_SKIP_ACTIVATION=0`.
    static var skipActivationGate: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains(forceActivationArgument) { return false }
        if args.contains(skipActivationArgument) { return true }
        let env = ProcessInfo.processInfo.environment["FCTV_SKIP_ACTIVATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if env == "0" || env == "false" || env == "no" { return false }
        if env == "1" || env == "true" || env == "yes" { return true }
        return true
    }
}

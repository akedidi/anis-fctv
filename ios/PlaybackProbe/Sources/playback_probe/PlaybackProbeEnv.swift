import Foundation

/// Maps `FCTV_STINJ_ENABLE` → `UserDefaults` for `RbliveHlsInjectEngine` (CLI / probe).
enum PlaybackProbeEnv {
    private static let udStinjKey = "fctv.rblive.stinj_enable"

    @MainActor
    static func applyInjectFromEnvironment() {
        let v = ProcessInfo.processInfo.environment["FCTV_STINJ_ENABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v == "1" || v == "true" || v == "yes" {
            UserDefaults.standard.set(true, forKey: udStinjKey)
        }
    }

    @MainActor
    static func forceStinjEnabled() {
        UserDefaults.standard.set(true, forKey: udStinjKey)
    }
}

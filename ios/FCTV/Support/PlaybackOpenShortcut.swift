import Foundation

/// Optional shortcuts so you can land on a specific match player from the shell or an Xcode scheme
/// without hunting the list (e.g. `FCTV_AUTO_OPEN_MATCH_NAME=Sinner` or id `2163266`).
enum PlaybackOpenShortcut {
    /// Sinner–Rublev Rome row id from the live/detail API (two streams on that match).
    private static let sinnerRomeMatchId: UInt64 = 2_163_266

    /// Numeric match id: `FCTV_AUTO_OPEN_MATCH_ID`, `--fctv-auto-open-match-id <id>`, or `--fctv-playback-sinner` → `2163266`.
    static var autoOpenMatchIdUInt64: UInt64? {
        if ProcessInfo.processInfo.arguments.contains("--fctv-playback-sinner") {
            return sinnerRomeMatchId
        }
        if let raw = ProcessInfo.processInfo.environment["FCTV_AUTO_OPEN_MATCH_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let v = UInt64(raw), v != 0 {
            return v
        }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fctv-auto-open-match-id"), i + 1 < args.count else { return nil }
        let raw = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = UInt64(raw), v != 0 else { return nil }
        return v
    }

    /// When the match is not in the loaded live list, `/api/match/detail` still needs `sportType`. Defaults to tennis for the Sinner shortcut.
    static func resolvedSportHint(forMatchId id: UInt64) -> Sport {
        if ProcessInfo.processInfo.arguments.contains("--fctv-playback-sinner"), id == sinnerRomeMatchId {
            return .tennis
        }
        if let raw = ProcessInfo.processInfo.environment["FCTV_AUTO_OPEN_MATCH_SPORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let s = Sport(rawValue: raw.lowercased()) {
            return s
        }
        return .tennis
    }

    /// Case-insensitive substring matched against `displayName`, league, and contender names.
    static var matchNameSubstring: String? {
        if let v = ProcessInfo.processInfo.environment["FCTV_AUTO_OPEN_MATCH_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return v
        }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fctv-auto-open-match"), i + 1 < args.count else { return nil }
        let v = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// After the player opens, start the first stream (`PlayerView`’s default server) like tapping Play.
    /// Opening by numeric id defaults to **on** (set `FCTV_AUTO_START_PLAYBACK=0` to only open the player).
    static var autoStartPlayback: Bool {
        if ProcessInfo.processInfo.arguments.contains("--fctv-auto-start-playback") { return true }
        if ProcessInfo.processInfo.arguments.contains("--fctv-playback-sinner") { return true }
        let e = ProcessInfo.processInfo.environment["FCTV_AUTO_START_PLAYBACK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if e == "1" || e == "true" || e == "yes" { return true }
        if e == "0" || e == "false" || e == "no" { return false }
        if autoOpenMatchIdUInt64 != nil { return true }
        return false
    }

    /// DEBUG/smoke: after `playbackProbe=playing`, collapse to mini-player (same as swipe-down).
    static var autoMinimizeAfterPlay: Bool {
        if ProcessInfo.processInfo.arguments.contains("--fctv-auto-minimize") { return true }
        let e = ProcessInfo.processInfo.environment["FCTV_AUTO_MINIMIZE_AFTER_PLAY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return e == "1" || e == "true" || e == "yes"
    }

    /// DEBUG/smoke: after playing, enter landscape fullscreen (streamsports proof).
    static var autoFullscreenAfterPlay: Bool {
        if ProcessInfo.processInfo.arguments.contains("--fctv-auto-fullscreen") { return true }
        let e = ProcessInfo.processInfo.environment["FCTV_AUTO_FULLSCREEN_AFTER_PLAY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return e == "1" || e == "true" || e == "yes"
    }

    /// Prefer a backend stream id (e.g. DZ FR `862318`): `FCTV_AUTO_OPEN_STREAM_ID`.
    static var autoOpenStreamId: Int64? {
        if let raw = ProcessInfo.processInfo.environment["FCTV_AUTO_OPEN_STREAM_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let v = Int64(raw), v != 0 {
            return v
        }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--fctv-auto-open-stream-id"), i + 1 < args.count else { return nil }
        return Int64(args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Prefer stream index in detail list: `FCTV_AUTO_OPEN_STREAM_INDEX` (0-based).
    static var autoOpenStreamIndex: Int? {
        if let raw = ProcessInfo.processInfo.environment["FCTV_AUTO_OPEN_STREAM_INDEX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let v = Int(raw), v >= 0 {
            return v
        }
        return nil
    }

    /// Pick preferred server for autoplay shortcuts.
    static func preferredServer(in streams: [StreamServer]) -> StreamServer? {
        if let sid = autoOpenStreamId,
           let hit = streams.first(where: { $0.backendStreamId == sid }) {
            return hit
        }
        if let idx = autoOpenStreamIndex, idx < streams.count {
            return streams[idx]
        }
        return streams.first
    }
}

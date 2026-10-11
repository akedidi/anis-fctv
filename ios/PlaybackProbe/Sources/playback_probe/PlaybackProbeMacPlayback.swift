#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import Foundation

@MainActor
enum PlaybackProbeMacPlayback {
    /// Keep resource-loader delegates alive (AVAssetResourceLoader holds them weakly).
    private static var retainedLoaders: [ObjectIdentifier: RbliveHlsAssetLoader] = [:]

    /// Builds player like `HLSPlayerView.configure`.
    /// - Parameter preferDirectHTTPS: When `true`, skips `rblivehls:` + `RbliveHlsAssetLoader` (public HLS / self-test). Rblive streams with STINJ / `_sou` should use `false`.
    static func makePlayer(resolved: RbliveResolvedPlayback, preferDirectHTTPS: Bool = false) -> (AVPlayer, RbliveHlsAssetLoader?) {
        let ua = resolved.extraHTTPHeaders["user-agent"] ?? resolved.extraHTTPHeaders["User-Agent"] ?? ""
        let rbUA = ua.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "rbapp/--dg-77-ios/unknown" : ua
        let headers = resolved.extraHTTPHeaders
        let envDirect = ProcessInfo.processInfo.environment["FCTV_DIRECT_HTTP"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let forceDirect = preferDirectHTTPS || envDirect == "1" || envDirect == "true" || envDirect == "yes"

        fputs("[probe] makePlayer forceDirect=\(forceDirect) url=\(resolved.url.absoluteString.prefix(100))\n", stderr)
        if !forceDirect {
            if let local = try? RbliveLocalHlsServer.shared.playableURL(for: resolved.url, extraHeaders: headers) {
                fputs("[probe] using local HLS proxy \(local.absoluteString.prefix(120))\n", stderr)
                var options: [String: Any] = [:]
                if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
                let asset = AVURLAsset(url: local, options: options.isEmpty ? nil : options)
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = true
                return (player, nil)
            }
            if let proxyURL = RbliveHlsProxyURL.wrappingHTTPS(resolved.url) {
                fputs("[probe] using rblivehls proxy \(proxyURL.absoluteString.prefix(80))\n", stderr)
                let loader = RbliveHlsAssetLoader(baseHTTPHeaders: headers, rbUserAgent: rbUA)
                let asset = AVURLAsset(url: proxyURL)
                let delegateQueue = DispatchQueue(label: "fctv.playback-probe.resource-loader")
                asset.resourceLoader.setDelegate(loader, queue: delegateQueue)
                asset.loadValuesAsynchronously(forKeys: ["playable", "tracks", "duration"]) {}
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = true
                retainedLoaders[ObjectIdentifier(player)] = loader
                return (player, loader)
            }
        }
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: resolved.url, options: options.isEmpty ? nil : options)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        return (player, nil)
    }

    /// Pumps the main run loop until playback clearly advances or timeout.
    static func waitUntilPlaying(player: AVPlayer, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLog = Date.distantPast
        while Date() < deadline {
            let t = player.currentTime().seconds
            if let item = player.currentItem {
                if item.status == .failed, let err = item.error {
                    throw PlaybackProbePlaybackError("AVPlayerItem error: \(err.localizedDescription)")
                }
                if item.status == .readyToPlay {
                    if !item.loadedTimeRanges.isEmpty {
                        let bufEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(item.loadedTimeRanges[0].timeRangeValue))
                        if bufEnd.isFinite, bufEnd > 0.5 { return }
                    }
                    if t.isFinite, t > 0.15 { return }
                }
            }
            if t.isFinite, t >= 0.75 {
                return
            }
            if player.timeControlStatus == .playing, player.rate > 0, player.currentItem?.isPlaybackLikelyToKeepUp == true {
                if t.isFinite, t > 0.1 { return }
            }
            if Date().timeIntervalSince(lastLog) > 5 {
                let status = player.currentItem?.status.rawValue ?? -1
                let err = player.currentItem?.error?.localizedDescription ?? "-"
                let tcs = player.timeControlStatus.rawValue
                fputs("[probe] still buffering… itemStatus=\(status) tcs=\(tcs) time=\(t) rate=\(player.rate) err=\(err)\n", stderr)
                lastLog = Date()
            }
            RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.05))
        }
        throw PlaybackProbePlaybackError("timeout: playback did not become ready within \(timeout)s")
    }

    static func showPreviewWindow(player: AVPlayer, seconds: TimeInterval) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FCTV playback-probe"
        window.center()

        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.player = player
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        player.play()

        let end = Date().addingTimeInterval(seconds)
        while Date() < end, window.isVisible {
            RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.1))
        }
        window.close()
        app.setActivationPolicy(.prohibited)
    }
}

struct PlaybackProbePlaybackError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
#endif

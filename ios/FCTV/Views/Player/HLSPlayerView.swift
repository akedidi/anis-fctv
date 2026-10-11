import AVFoundation
import AVKit
import SwiftUI
import UIKit

extension Notification.Name {
    /// Same name as streamsports — starts/stops system Picture-in-Picture.
    static let fctvTogglePiP = Notification.Name("TogglePiP")
}

/// Hosts an `AVPlayerLayer` as the view's layer so PiP works from **inline** detail
/// (AVPlayerViewController only auto-PiPs reliably once presented fullscreen).
final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Thin AVKit wrapper providing HLS playback, Picture-in-Picture and AirPlay,
/// matching the original `HLSVideoPlayer` (ExoPlayer) capabilities.
///
/// When STINJ / `_sou` is needed, assets use `rblivehls:` + `RbliveHlsAssetLoader`.
/// Plain cleartext HLS (typical `original_info` manifests) plays directly — ATS already
/// allows arbitrary loads for media in `Info.plist`.
struct HLSPlayerView: UIViewRepresentable {
    let url: URL?
    let httpHeaders: [String: String]?
    @Binding var isPlaying: Bool
    /// `idle` / `loading` / `playing` / `failed` — updated from AVFoundation for UI tests.
    @Binding var playbackProbe: String
    /// Existing session pipeline to attach (detail ↔ mini) instead of creating a new `AVPlayer`.
    var reusePlayer: AVPlayer?
    /// When `false`, handoff — do not pause and do not clear `playerLayer.player` on dismantle.
    var pauseWhenNotPlaying: Bool
    /// Registers the created/attached `AVPlayer` on the global session (single active pipeline).
    var onPipelineReady: ((AVPlayer, RbliveHlsAssetLoader?) -> Void)?
    /// `true` → aspect fill (zoom to edges); `false` → aspect fit (streamsports pinch).
    var isZoomedToFill: Bool

    init(
        url: URL?,
        httpHeaders: [String: String]? = nil,
        isPlaying: Binding<Bool>,
        playbackProbe: Binding<String> = .constant("idle"),
        reusePlayer: AVPlayer? = nil,
        pauseWhenNotPlaying: Bool = true,
        onPipelineReady: ((AVPlayer, RbliveHlsAssetLoader?) -> Void)? = nil,
        isZoomedToFill: Bool = false
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self._isPlaying = isPlaying
        self._playbackProbe = playbackProbe
        self.reusePlayer = reusePlayer
        self.pauseWhenNotPlaying = pauseWhenNotPlaying
        self.onPipelineReady = onPipelineReady
        self.isZoomedToFill = isZoomedToFill
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        context.coordinator.hostView = view
        context.coordinator.pauseWhenNotPlaying = pauseWhenNotPlaying
        configure(host: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        context.coordinator.hostView = view
        context.coordinator.reusePlayer = reusePlayer
        context.coordinator.pauseWhenNotPlaying = pauseWhenNotPlaying
        if context.coordinator.configuredSourceURL != url
            || (reusePlayer != nil && view.player !== reusePlayer) {
            configure(host: view, coordinator: context.coordinator)
        }
        let gravity: AVLayerVideoGravity = isZoomedToFill ? .resizeAspectFill : .resizeAspect
        if view.videoGravity != gravity {
            view.videoGravity = gravity
        }
        context.coordinator.applyPlaybackState(isPlaying: isPlaying)
        context.coordinator.ensurePiPReady()
    }

    static func dismantleUIView(_ view: PlayerLayerHostView, coordinator: Coordinator) {
        coordinator.stopPlaybackObservation()
        if coordinator.pauseWhenNotPlaying {
            coordinator.teardownPiP()
            // Normal teardown (user paused / left) — clear layer binding.
            if view.player != nil {
                fputs("[player] detach layer \(ObjectIdentifier(view.player!))\n", stderr)
            }
            view.player = nil
        } else {
            // Minimize handoff: keep AVPlayer running; only drop this layer reference.
            // Clearing `playerLayer.player` moves ownership to the next view that assigns it.
            coordinator.relinquishPiPForHandoff()
            if view.player != nil {
                fputs("[player] handoff detach (keep pipeline \(ObjectIdentifier(view.player!)))\n", stderr)
            }
            view.player = nil
        }
        coordinator.hlsLoader = nil
        coordinator.configuredSourceURL = nil
        coordinator.resourceLoaderQueue = nil
        coordinator.reusePlayer = nil
        coordinator.hostView = nil
    }

    private func configure(host: PlayerLayerHostView, coordinator: Coordinator) {
        coordinator.stopPlaybackObservation()

        guard let url else {
            coordinator.teardownPiP()
            host.player = nil
            coordinator.hlsLoader = nil
            coordinator.configuredSourceURL = nil
            coordinator.resourceLoaderQueue = nil
            playbackProbe = "idle"
            return
        }

        // Reuse session pipeline — assign once; do not bounce audio session / play().
        if let existing = reusePlayer {
            coordinator.configuredSourceURL = url
            coordinator.reusePlayer = existing
            if host.player !== existing {
                host.player = existing
            }
            onPipelineReady?(existing, nil)
            coordinator.startPlaybackObservation(player: existing, probe: $playbackProbe)
            coordinator.schedulePiPSetup()
            fputs("[player] attach existing \(ObjectIdentifier(existing))\n", stderr)
            return
        }

        if host.player != nil, coordinator.configuredSourceURL == url {
            coordinator.applyPlaybackState(isPlaying: isPlaying)
            return
        }

        coordinator.teardownPiP()
        host.player = nil
        coordinator.configuredSourceURL = url
        coordinator.reusePlayer = nil

        let ua = httpHeaders?["user-agent"] ?? httpHeaders?["User-Agent"] ?? ""
        let rbUA = ua.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "rbapp/--dg-77-ios/unknown" : ua
        let hdrs = httpHeaders ?? [:]

        let useProxy = Self.shouldUseHlsProxy(for: url)
        let player: AVPlayer
        let loaderOut: RbliveHlsAssetLoader?
        if useProxy, let local = try? RbliveLocalHlsServer.shared.playableURL(for: url, extraHeaders: hdrs) {
            coordinator.hlsLoader = nil
            coordinator.resourceLoaderQueue = nil
            loaderOut = nil
            var options: [String: Any] = [:]
            if !hdrs.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = hdrs }
            let asset = AVURLAsset(url: local, options: options.isEmpty ? nil : options)
            let item = Self.makePlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
            fputs("[player] HLS via local proxy \(local.absoluteString.prefix(120))\n", stderr)
        } else if useProxy, let proxyURL = RbliveHlsProxyURL.wrappingHTTPS(url) {
            let loader = RbliveHlsAssetLoader(baseHTTPHeaders: hdrs, rbUserAgent: rbUA)
            coordinator.hlsLoader = loader
            loaderOut = loader
            let queue = DispatchQueue(label: "fctv.hls.resource-loader")
            coordinator.resourceLoaderQueue = queue
            let asset = AVURLAsset(url: proxyURL)
            asset.resourceLoader.setDelegate(loader, queue: queue)
            let item = Self.makePlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
            fputs("[player] HLS via rblivehls proxy \(url.absoluteString.prefix(100))\n", stderr)
        } else {
            coordinator.hlsLoader = nil
            coordinator.resourceLoaderQueue = nil
            loaderOut = nil
            var options: [String: Any] = [:]
            if !hdrs.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = hdrs
            }
            let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
            let item = Self.makePlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)
            fputs("[player] HLS direct \(url.absoluteString.prefix(100))\n", stderr)
        }
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.isMuted = false
        host.player = player
        onPipelineReady?(player, loaderOut)
        coordinator.startPlaybackObservation(player: player, probe: $playbackProbe)
        coordinator.activateAudioSessionIfNeeded()
        coordinator.schedulePiPSetup()
        coordinator.applyPlaybackState(isPlaying: isPlaying)
    }

    private static func makePlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        // Slightly larger buffer reduces brief live-edge underrun hitches.
        item.preferredForwardBufferDuration = 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    /// Prefer `rblivehls:` proxy for CDN / CSL streams so segments with `_ctump` are rewritten to CTU.
    /// Plain cleartext `play.*.top` manifests can still go direct.
    /// URLs already from `fctv33-stream-resolver` `/api/hls` play as-is (Node proxy handles referer + CSL).
    private static func shouldUseHlsProxy(for url: URL) -> Bool {
        if FCTVStreamResolverClient.isProxiedPlayableURL(url) { return false }
        let raw = url.absoluteString.lowercased()
        if raw.contains("_sou") { return true }
        if raw.contains("_ctump") { return true }
        if raw.contains("/cfall/") || raw.contains("/v3b/") || raw.contains("/token-") { return true }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-stinj-enabled") { return true }
        let e = ProcessInfo.processInfo.environment["FCTV_STINJ_ENABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if e == "1" || e == "true" || e == "yes" { return true }
        let force = ProcessInfo.processInfo.environment["FCTV_DIRECT_HTTP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if force == "1" || force == "true" || force == "yes" { return false }
        if raw.hasPrefix("https://") { return true }
        return false
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var hlsLoader: RbliveHlsAssetLoader?
        /// Source URL last passed to `configure` (not the `rblivehls:` asset URL).
        var configuredSourceURL: URL?
        var resourceLoaderQueue: DispatchQueue?
        var reusePlayer: AVPlayer?
        var pauseWhenNotPlaying: Bool = true
        weak var hostView: PlayerLayerHostView?
        private var probe: Binding<String>?
        private weak var observedPlayer: AVPlayer?
        private var timer: Timer?
        private var statusObservation: NSKeyValueObservation?
        private var itemObservation: NSKeyValueObservation?
        private(set) var pipController: AVPictureInPictureController?
        private var pipPossibleObservation: NSKeyValueObservation?
        private var pipRetryWorkItem: DispatchWorkItem?
        /// True while system PiP owns the stream — skip resign-active / update churn.
        private var isPiPActive = false
        private var lastLoggedTCS: AVPlayer.TimeControlStatus?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(togglePiP),
                name: .fctvTogglePiP,
                object: nil
            )
            // Must start PiP while scene is still foregroundActive (willResignActive).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            pipRetryWorkItem?.cancel()
            pipPossibleObservation?.invalidate()
        }

        func activateAudioSessionIfNeeded() {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playback,
                    mode: .moviePlayback,
                    options: [.allowAirPlay, .allowBluetoothA2DP]
                )
                try session.setActive(true)
            } catch {
                fputs("[PiP] audio session: \(error.localizedDescription)\n", stderr)
            }
        }

        func schedulePiPSetup() {
            pipRetryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.setupPiP(attempt: 0)
            }
            pipRetryWorkItem = work
            DispatchQueue.main.async(execute: work)
        }

        func ensurePiPReady() {
            // Never recreate PiP while active — teardown would stop/restart the window.
            if isPiPActive || pipController?.isPictureInPictureActive == true { return }
            if pipController == nil {
                schedulePiPSetup()
            }
        }

        /// Sync AVPlayer with SwiftUI `isPlaying` without redundant play()/pause().
        func applyPlaybackState(isPlaying: Bool) {
            // While PiP is up, the system owns playback — poking play()/pause() causes a hitch.
            if isPiPActive || pipController?.isPictureInPictureActive == true { return }
            guard let player = hostView?.player ?? observedPlayer else { return }
            let rate = player.rate
            if isPlaying {
                if rate < 0.05 { player.play() }
            } else if pauseWhenNotPlaying, rate > 0.05 {
                player.pause()
            }
        }

        private func setupPiP(attempt: Int) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                fputs("[PiP] Not supported on this device/simulator\n", stderr)
                return
            }
            // Don't tear down a live PiP to "refresh" the controller.
            if isPiPActive || pipController?.isPictureInPictureActive == true { return }

            guard let host = hostView, host.player != nil else {
                if attempt < 10 {
                    let work = DispatchWorkItem { [weak self] in
                        self?.setupPiP(attempt: attempt + 1)
                    }
                    pipRetryWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                } else {
                    fputs("[PiP] host/player missing after retries\n", stderr)
                }
                return
            }
            let layer = host.playerLayer
            guard layer.bounds.width > 1, layer.bounds.height > 1 else {
                if attempt < 12 {
                    let work = DispatchWorkItem { [weak self] in
                        self?.setupPiP(attempt: attempt + 1)
                    }
                    pipRetryWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                } else {
                    fputs("[PiP] layer bounds not ready\n", stderr)
                }
                return
            }

            if pipController?.playerLayer === layer {
                return
            }
            // Replace only when inactive.
            teardownPiPKeepingPlayback(stopIfActive: false)

            activateAudioSessionIfNeeded()
            guard let pip = AVPictureInPictureController(playerLayer: layer) else {
                fputs("[PiP] Failed to create controller\n", stderr)
                return
            }
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = pip
            pipPossibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { ctrl, _ in
                fputs("[PiP] possible=\(ctrl.isPictureInPicturePossible)\n", stderr)
            }
            fputs("[PiP] Controller ready (inline) possible=\(pip.isPictureInPicturePossible) bounds=\(layer.bounds)\n", stderr)
        }

        func teardownPiP() {
            teardownPiPKeepingPlayback(stopIfActive: true)
        }

        /// Drop PiP controller reference without stopping playback / audio (detail→mini).
        func relinquishPiPForHandoff() {
            pipRetryWorkItem?.cancel()
            pipRetryWorkItem = nil
            pipPossibleObservation?.invalidate()
            pipPossibleObservation = nil
            pipController?.delegate = nil
            pipController = nil
            isPiPActive = false
        }

        private func teardownPiPKeepingPlayback(stopIfActive: Bool) {
            pipRetryWorkItem?.cancel()
            pipRetryWorkItem = nil
            pipPossibleObservation?.invalidate()
            pipPossibleObservation = nil
            if stopIfActive, let pip = pipController, pip.isPictureInPictureActive {
                pip.stopPictureInPicture()
            }
            pipController?.delegate = nil
            pipController = nil
            if stopIfActive { isPiPActive = false }
        }

        @objc func togglePiP() {
            fputs("[PiP] Toggle requested\n", stderr)
            startPiPIfPossible(reason: "toggle")
        }

        @objc private func appWillResignActive() {
            // Already in PiP: do nothing (no audio re-activate, no play(), no re-start).
            if isPiPActive || pipController?.isPictureInPictureActive == true {
                fputs("[PiP] resignActive — already in PiP, skip\n", stderr)
                return
            }
            // Explicit start while still foregroundActive (auto flag as primary).
            startPiPIfPossible(reason: "willResignActive")
        }

        private func startPiPIfPossible(reason: String) {
            if let pip = pipController, pip.isPictureInPictureActive || isPiPActive {
                if reason == "toggle" {
                    pip.stopPictureInPicture()
                }
                return
            }

            if pipController == nil {
                setupPiP(attempt: 0)
            }
            guard let pip = pipController else {
                fputs("[PiP] No controller (\(reason))\n", stderr)
                return
            }

            let playing = (observedPlayer?.timeControlStatus == .playing)
                || ((observedPlayer?.rate ?? 0) > 0.05)
                || ((hostView?.player?.rate ?? 0) > 0.05)
            guard playing || reason == "toggle" else {
                fputs("[PiP] Skip \(reason) — not playing\n", stderr)
                return
            }
            if pip.isPictureInPicturePossible {
                fputs("[PiP] start (\(reason))\n", stderr)
                pip.startPictureInPicture()
            } else {
                fputs("[PiP] Not possible yet (\(reason)) — waiting briefly\n", stderr)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, let pip = self.pipController,
                          !pip.isPictureInPictureActive, !self.isPiPActive
                    else { return }
                    if pip.isPictureInPicturePossible {
                        fputs("[PiP] start retry (\(reason))\n", stderr)
                        pip.startPictureInPicture()
                    } else {
                        fputs("[PiP] still not possible (\(reason))\n", stderr)
                    }
                }
            }
        }

        func stopPlaybackObservation() {
            timer?.invalidate()
            timer = nil
            statusObservation?.invalidate()
            statusObservation = nil
            itemObservation?.invalidate()
            itemObservation = nil
            probe = nil
            observedPlayer = nil
        }

        func startPlaybackObservation(player: AVPlayer, probe: Binding<String>) {
            stopPlaybackObservation()
            self.probe = probe
            observedPlayer = player
            probe.wrappedValue = "loading"

            itemObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    self?.publish(from: p)
                }
            }
            statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    self?.publish(from: p)
                }
            }

            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let p = self.observedPlayer else { return }
                self.publish(from: p)
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func publish(from p: AVPlayer) {
            guard let probe else { return }
            if let err = p.currentItem?.error ?? p.error {
                fputs("[player] AV error: \(err.localizedDescription)\n", stderr)
                probe.wrappedValue = "failed"
                stopPlaybackObservation()
                return
            }
            if p.currentItem?.status == .failed {
                let msg = p.currentItem?.error?.localizedDescription ?? "item failed"
                fputs("[player] AV item failed: \(msg)\n", stderr)
                probe.wrappedValue = "failed"
                stopPlaybackObservation()
                return
            }
            let tcs = p.timeControlStatus
            if lastLoggedTCS != tcs {
                lastLoggedTCS = tcs
                let label: String = switch tcs {
                case .paused: "paused"
                case .waitingToPlayAtSpecifiedRate: "waiting"
                case .playing: "playing"
                @unknown default: "other"
                }
                fputs("[player] timeControl=\(label) rate=\(p.rate) probe=\(probe.wrappedValue)\n", stderr)
            }
            if tcs == .playing || p.rate > 0.05 {
                if probe.wrappedValue != "playing" {
                    fputs("[player] playbackProbe=playing rate=\(p.rate)\n", stderr)
                    // First frame often unlocks isPictureInPicturePossible.
                    ensurePiPReady()
                }
                probe.wrappedValue = "playing"
            } else if tcs == .waitingToPlayAtSpecifiedRate, probe.wrappedValue == "playing" {
                // Stall after live window — keep probe as playing but surface wait reason.
                if let reason = p.reasonForWaitingToPlay {
                    fputs("[player] waiting reason=\(reason.rawValue)\n", stderr)
                }
            }
        }

        // MARK: AVPictureInPictureControllerDelegate

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            isPiPActive = true
        }

        func pictureInPictureControllerDidStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            isPiPActive = true
            fputs("[PiP] Did start\n", stderr)
        }

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            isPiPActive = false
            fputs("[PiP] Did stop\n", stderr)
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            fputs("[PiP] Failed to start: \(error.localizedDescription)\n", stderr)
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}

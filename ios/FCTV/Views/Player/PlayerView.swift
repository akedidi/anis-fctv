import AVFoundation
import SwiftUI

/// Match detail + video player (mirrors `com.rblive.app.ui.player.PlayerActivity`).
struct PlayerView: View {
    /// Pull distance on the fixed player chrome before collapsing to the mini-player.
    private static let minimizePullDistance: CGFloat = 120
    /// Rubber-band past top of the content ScrollView (UIKit offset resists harder than a free drag).
    private static let minimizeScrollPullDistance: CGFloat = 80

    let match: LiveMatch
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(PlaybackSession.self) private var playbackSession
    @State private var selectedServer: StreamServer?
    @State private var selectedTab: DetailTab = .overview
    /// Live-updating copy of the opened match (scores / clock / streams).
    @State private var displayedMatch: LiveMatch
    @State private var highlights: [MatchHighlight] = []
    @State private var detailRefreshTask: Task<Void, Never>?
    @State private var isPlaying = false
    @State private var resolvedPlaybackURL: URL?
    @State private var resolvedForServerId: String?
    /// Backend stream id used for the last successful resolve (survives list→detail id churn).
    @State private var resolvedForBackendStreamId: Int64?
    @State private var streamError: String?
    @State private var isResolvingPlayback = false
    @State private var resolvedPlaybackHeaders: [String: String]?
    @State private var playerHTTPHeaders: [String: String]?
    @State private var playbackProbe = "idle"
    @State private var didApplyAutoStartPlayback = false
    /// True until first successful/attempted autoplay after opening detail (not on user pause).
    @State private var awaitingInitialAutoplay = true
    /// One-shot recovery after `/api/match/detail` if list-based autoplay left us without a URL.
    @State private var didRecoverAutoplayAfterDetail = false
    /// Avoid flashing placeholder stream labels from the live list before `/api/match/detail`.
    @State private var serversHydratedFromDetail = false
    /// Cancels stale resolve results when the user switches servers quickly.
    @State private var resolveGeneration = 0
    /// Interactive drag offset while swiping down to mini-player (streamsports).
    @State private var dismissDragOffset: CGFloat = 0
    /// Avoid double-firing minimize from overscroll + drag in the same gesture.
    @State private var didMinimizeFromGesture = false
    @State private var didAutoMinimize = false
    /// Forced landscape fullscreen (streamsports `isLandscapeMode`).
    @State private var isLandscapeMode = false
    /// Aspect fill vs fit (streamsports pinch / zoom toggle).
    @State private var isZoomedToFill = false
    /// In-player chrome visibility (streamsports `showControls`).
    @State private var showControls = true
    /// Bumps to cancel stale auto-hide work items.
    @State private var controlsHideEpoch = 0
    @State private var didAutoFullscreen = false

    init(match: LiveMatch, onClose: @escaping () -> Void) {
        self.match = match
        self.onClose = onClose
        _displayedMatch = State(initialValue: match)
        _selectedServer = State(initialValue: PlaybackOpenShortcut.preferredServer(in: match.streams) ?? match.streams.first)
        _highlights = State(initialValue: Self.seedHighlights(for: match))
        // If the home row already has real channel names, show them; otherwise wait for detail.
        _serversHydratedFromDetail = State(
            initialValue: match.streams.contains(where: \.hasReliableChannelName)
        )
    }

    private var playbackURL: URL? {
        guard let s = selectedServer else { return nil }
        if let u = s.playbackURL { return u }
        if s.id == resolvedForServerId { return resolvedPlaybackURL }
        if let bid = s.backendStreamId, bid != 0, bid == resolvedForBackendStreamId {
            return resolvedPlaybackURL
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.Colors.background.ignoresSafeArea()

            if isLandscapeMode {
                landscapeFullscreen
            } else {
                // Player chrome is OUTSIDE the ScrollView so pull-to-mini never fights page scroll.
                VStack(spacing: 0) {
                    dismissiblePlayerChrome
                        .frame(maxWidth: .infinity)
                        // Prefer full-width 16:9 height over compressing the player for the list.
                        .layoutPriority(1)
                        .offset(y: max(0, dismissDragOffset))
                        .gesture(minimizeDragGesture)

                    ScrollView {
                        VStack(spacing: 0) {
                            serversSection
                                .padding(.horizontal, Theme.Spacing.l)
                                .padding(.bottom, Theme.Spacing.l)

                            DetailTabBar(selected: selectedTab) { selectedTab = $0 }
                                .padding(.horizontal, Theme.Spacing.l)

                            DetailTabContent(
                                tab: selectedTab,
                                match: displayedMatch,
                                highlights: highlights
                            )
                                .padding(.horizontal, Theme.Spacing.l)
                                .padding(.top, Theme.Spacing.m)
                                .padding(.bottom, Theme.Spacing.xxl)

                            // Real UIScrollView contentOffset (rubber-band) → mini-player.
                            PlayerScrollOffsetReader(onOffsetY: handleScrollContentOffset)
                                .frame(width: 0, height: 0)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .ignoresSafeArea(edges: .top)

                topChrome
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.root")
        .preferredColorScheme(.dark)
        .statusBarHidden(isLandscapeMode)
        .ignoresSafeArea(edges: isLandscapeMode ? .all : [])
        .onAppear {
            configureAudioSession()
            // Different event than mini-player → kill previous AVPlayer first (streamsports).
            playbackSession.prepareForNewEvent(matchId: match.id)
            restoreFromMiniSessionIfNeeded()
            // Immediate autoplay with list data; detail API enriches servers in parallel.
            if awaitingInitialAutoplay, selectedServer != nil {
                didApplyAutoStartPlayback = true
                awaitingInitialAutoplay = false
                Task { await startPlayback(for: selectedServer) }
            }
            // Don't block first paint — refresh detail right away (was waiting ~1.5s on home).
            startDetailAutoRefresh(immediate: true)
            Task { await loadHistoricalHighlights() }
        }
        .onDisappear {
            detailRefreshTask?.cancel()
            detailRefreshTask = nil
            exitLandscapeIfNeeded()
        }
        .onChange(of: playbackProbe) { _, new in
            if new == "failed", streamError == nil {
                streamError = "Playback failed (AVPlayer / stream unreachable)."
                isPlaying = false
            }
            fputs("[playbackProbe]=\(new)\n", stderr)
            if new == "playing",
               PlaybackOpenShortcut.autoMinimizeAfterPlay,
               !didAutoMinimize {
                didAutoMinimize = true
                // Brief beat so the playing frame is settled before dock hand-off.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    minimizeToMiniPlayer()
                }
            }
            if new == "playing" {
                showControls = true
                scheduleAutoHideControls()
            }
            if new == "playing",
               PlaybackOpenShortcut.autoFullscreenAfterPlay,
               !didAutoFullscreen,
               !isLandscapeMode {
                didAutoFullscreen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    toggleFullscreen()
                }
            }
        }
    }

    /// Full-bleed landscape player (streamsports `isLandscapeMode`).
    private var landscapeFullscreen: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            videoStage(cornerRadius: 0, aspectFit: false)
                .ignoresSafeArea()
            airPlayToolbarButton
                .padding(.top, 16)
                .padding(.trailing, 20)
        }
        .accessibilityIdentifier("player.landscapeFullscreen")
    }

    /// Stable identity so portrait ↔ landscape does not recreate AVPlayer.
    private func playerSurfaceID(for url: URL) -> String {
        "hls-\(match.id)-\(url.absoluteString)"
    }

    /// Shared video + in-player controls (portrait inset or landscape full-bleed).
    @ViewBuilder
    private func videoStage(cornerRadius: CGFloat, aspectFit: Bool) -> some View {
        ZStack {
            Color.black
            if isPlaying, let url = playbackURL {
                HLSPlayerView(
                    url: url,
                    httpHeaders: playerHTTPHeaders,
                    isPlaying: $isPlaying,
                    playbackProbe: $playbackProbe,
                    reusePlayer: playbackSession.reusablePlayer(for: url),
                    // During detail→mini handoff, unmounting must not pause the shared pipeline.
                    pauseWhenNotPlaying: !didMinimizeFromGesture,
                    onPipelineReady: { player, loader in
                        playbackSession.bindPlayer(player, hlsLoader: loader)
                    },
                    isZoomedToFill: isZoomedToFill
                )
                .id(playerSurfaceID(for: url))
            } else {
                placeholderOverlay
            }

            // Tap empty video to toggle chrome (when overlay hidden).
            if isPlaying, !showControls {
                Color.black.opacity(0.001)
                    .onTapGesture { toggleControls() }
            }

            if isPlaying, showControls {
                PlayerControlsOverlay(
                    title: displayedMatch.displayName,
                    isLandscape: isLandscapeMode,
                    isPlaying: isPlaying,
                    isMuted: playbackSession.isMuted,
                    onPlayPause: {
                        isPlaying.toggle()
                        scheduleAutoHideControls()
                    },
                    onToggleMute: {
                        playbackSession.toggleMute()
                    },
                    onTogglePiP: {
                        NotificationCenter.default.post(name: .fctvTogglePiP, object: nil)
                    },
                    onToggleFullscreen: toggleFullscreen,
                    onUserActivity: scheduleAutoHideControls,
                    onRequestHide: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls = false
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: aspectFit ? Theme.Sizing.cornerMedium : cornerRadius, style: .continuous))
        .modifier(PlayerAspectModifier(enabled: aspectFit))
        // Pinch-to-zoom only (streamsports) — works over the controls overlay too.
        .simultaneousGesture(pinchZoomGesture)
    }

    /// Pinch out → aspect fill (edges); pinch in → aspect fit. No zoom button.
    private var pinchZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Live preview while pinching (threshold ~1.0).
                let fill = value > 1.05
                if isZoomedToFill != fill {
                    isZoomedToFill = fill
                }
            }
            .onEnded { value in
                let fill = value > 1.0
                fputs("[zoom] pinch=\(String(format: "%.2f", value)) → fill=\(fill)\n", stderr)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isZoomedToFill = fill
                }
            }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls {
            scheduleAutoHideControls()
        }
    }

    /// Auto-hide after ~4s while playing (streamsports).
    private func scheduleAutoHideControls() {
        controlsHideEpoch += 1
        let epoch = controlsHideEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard epoch == controlsHideEpoch, showControls, isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = false
            }
        }
    }

    private func toggleFullscreen() {
        if isLandscapeMode {
            DeviceRotation.rotate(to: .portrait)
            isLandscapeMode = false
        } else {
            DeviceRotation.rotate(to: .landscapeRight)
            isLandscapeMode = true
        }
        showControls = true
        scheduleAutoHideControls()
        fputs("[fullscreen] landscape=\(isLandscapeMode) zoomFill=\(isZoomedToFill)\n", stderr)
    }

    private func exitLandscapeIfNeeded() {
        guard isLandscapeMode else { return }
        DeviceRotation.rotate(to: .portrait)
        isLandscapeMode = false
    }

    /// Portrait chrome: back + AirPlay (always visible).
    private var topChrome: some View {
        HStack {
            Button(action: closeTapped) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.close")
            .accessibilityLabel("Close player")

            Spacer()

            airPlayToolbarButton
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, 12)
    }

    private var airPlayToolbarButton: some View {
        AirPlayRouteButton()
            .frame(width: 28, height: 28)
            .padding(10)
            .background(Circle().fill(Color.black.opacity(0.4)))
            .accessibilityIdentifier("player.airPlayToolbarButton")
            .accessibilityLabel("AirPlay")
    }

    /// Servers list — hidden until we have real channel names (no "Live stream" / "Stream N" flash).
    @ViewBuilder
    private var serversSection: some View {
        let reliable = displayedMatch.streams.filter(\.hasReliableChannelName)
        if serversHydratedFromDetail, !reliable.isEmpty {
            ServerListView(
                streams: reliable,
                selected: selectedServer
            ) { server in
                selectServer(server)
            }
        } else if !serversHydratedFromDetail {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Servers")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading channels…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("player.servers.loading")
        }
    }

    /// Header + video only — intentional pull-down zone for mini-player.
    private var dismissiblePlayerChrome: some View {
        VStack(spacing: 0) {
            // Affordance like streamsports sheet handle (portrait).
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 40, height: 4)
                .padding(.top, 56)
                .padding(.bottom, 6)

            MatchDetailHeader(match: displayedMatch, topPadding: 8)
                .padding(.bottom, Theme.Spacing.s)

            playerSurface
                .padding(.horizontal, 0)
                .padding(.bottom, Theme.Spacing.m)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Pull down on the fixed player chrome → mini-player (distance only, decided on release).
    private var minimizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !isLandscapeMode, !didMinimizeFromGesture else { return }
                let dy = value.translation.height
                let dx = value.translation.width
                guard dy > 0, dy > abs(dx) else {
                    if dismissDragOffset != 0 { dismissDragOffset = 0 }
                    return
                }
                dismissDragOffset = min(dy, 280)
            }
            .onEnded { value in
                guard !isLandscapeMode, !didMinimizeFromGesture else { return }
                let dy = value.translation.height
                let dx = value.translation.width
                if dy > abs(dx), dy >= Self.minimizePullDistance {
                    didMinimizeFromGesture = true
                    fputs("[mini] dismiss chrome dy=\(Int(dy))\n", stderr)
                    minimizeToMiniPlayer()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }

    /// `contentOffset.y` adjusted for inset: `0` at top, negative while rubber-banding downward.
    private func handleScrollContentOffset(_ adjustedY: CGFloat) {
        guard !isLandscapeMode, !didMinimizeFromGesture else { return }
        let pull = -adjustedY
        guard pull >= Self.minimizeScrollPullDistance else { return }
        didMinimizeFromGesture = true
        fputs("[mini] dismiss scroll pull=\(Int(pull))\n", stderr)
        minimizeToMiniPlayer()
    }

    private var playerSurface: some View {
        ZStack {
            videoStage(cornerRadius: Theme.Sizing.cornerLarge, aspectFit: true)

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("player.uiTest.playbackState")
                .accessibilityLabel("Playback state")
                .accessibilityValue(playbackProbe)
        }
    }

    private var placeholderOverlay: some View {
        VStack(spacing: Theme.Spacing.m) {
            if let streamError {
                Text(streamError)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.live)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.m)
                Button {
                    Task { await startPlayback(for: selectedServer) }
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.Colors.accent.opacity(0.85)))
                }
                .buttonStyle(.plain)
            } else if isResolvingPlayback {
                ProgressView()
                    .tint(.white)
                Text("Starting stream…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            } else if displayedMatch.streams.isEmpty {
                Image(systemName: "tv.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Stream is processing, please wait")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                // Fallback only if autoplay was skipped (e.g. restore race); still one tap.
                Button {
                    Task { await startPlayback(for: selectedServer) }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white)
                        Text(selectedServer?.displayName ?? "Live Stream")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.playButton")
            }
        }
    }

    /// Back chevron: leave detail entirely — do **not** dock a mini-player.
    private func closeTapped() {
        exitLandscapeIfNeeded()
        detailRefreshTask?.cancel()
        detailRefreshTask = nil
        isPlaying = false
        playbackSession.stop()
        dismissDragOffset = 0
        fputs("[player] back → close (no mini-player)\n", stderr)
        onClose()
    }

    /// Hand off playing stream to the global mini-player, then dismiss full-screen detail.
    private func minimizeToMiniPlayer() {
        exitLandscapeIfNeeded()
        let url = playbackURL
        let playing = isPlaying
        fputs(
            "[mini] minimize playing=\(playing) match=\(match.id) url=\(url?.absoluteString.prefix(80) ?? "nil")\n",
            stderr
        )
        if playing, let url {
            // Keep local isPlaying=true so video stays on detail during cover dismiss.
            // Dock stays suppressed until HomeView onDismiss reveals the mini player.
            didMinimizeFromGesture = true
            playbackSession.minimize(
                match: displayedMatch,
                server: selectedServer,
                url: url,
                headers: playerHTTPHeaders,
                playing: true
            )
        } else {
            playbackSession.minimize(
                match: displayedMatch,
                server: selectedServer,
                url: url,
                headers: playerHTTPHeaders,
                playing: false
            )
            didMinimizeFromGesture = true
        }
        dismissDragOffset = 0
        onClose()
    }

    private func restoreFromMiniSessionIfNeeded() {
        guard playbackSession.match?.id == match.id,
              let url = playbackSession.playbackURL
        else { return }
        if let s = playbackSession.server {
            selectedServer = s
            resolvedForServerId = s.id
            resolvedForBackendStreamId = s.backendStreamId
        }
        resolvedPlaybackURL = url
        playerHTTPHeaders = playbackSession.httpHeaders
        isPlaying = playbackSession.isPlaying
        awaitingInitialAutoplay = false
        didApplyAutoStartPlayback = true
        didRecoverAutoplayAfterDetail = true
        // Keep the same AVPlayer — only hide the dock (do not stop/rebuffer).
        playbackSession.expand()
    }

    /// Tap another server → tear down current source and autoplay the new one immediately.
    private func selectServer(_ server: StreamServer) {
        if sameStream(server, selectedServer), isPlaying, playbackURL != nil { return }
        selectedServer = server
        streamError = nil
        playbackProbe = "idle"
        resolvedForServerId = nil
        resolvedForBackendStreamId = nil
        resolvedPlaybackURL = nil
        resolvedPlaybackHeaders = nil
        playerHTTPHeaders = nil
        isPlaying = false
        Task { await startPlayback(for: server) }
    }

    private func sameStream(_ a: StreamServer?, _ b: StreamServer?) -> Bool {
        guard let a, let b else { return false }
        if a.id == b.id { return true }
        if let aid = a.backendStreamId, let bid = b.backendStreamId, aid != 0, aid == bid { return true }
        return false
    }

    /// Resolve (if needed) then set `isPlaying` so `HLSPlayerView` mounts and calls `AVPlayer.play()`.
    private func startPlayback(for server: StreamServer?) async {
        guard let s = server else { return }
        // Ensure no leftover mini-player from another event keeps audio/video alive.
        playbackSession.prepareForNewEvent(matchId: match.id)
        resolveGeneration += 1
        let generation = resolveGeneration
        streamError = nil
        playbackProbe = "idle"

        if !FCTVStreamResolverClient.isEnabled, s.playbackURL != nil {
            guard generation == resolveGeneration else { return }
            resolvedForServerId = s.id
            resolvedForBackendStreamId = s.backendStreamId
            resolvedPlaybackURL = s.playbackURL
            await refreshPlayerHTTPHeaders()
            guard generation == resolveGeneration else { return }
            isPlaying = true
            fputs("[autoplay] ready server=\(s.displayName) (direct URL)\n", stderr)
            return
        }

        isResolvingPlayback = true
        playbackProbe = "loading"
        fputs("[autoplay] resolve start server=\(s.displayName) id=\(s.id) sid=\(s.backendStreamId.map(String.init) ?? "-")\n", stderr)
        defer {
            if generation == resolveGeneration {
                isResolvingPlayback = false
            }
        }
        do {
            let resolved = try await MatchService.shared.resolvePlaybackURL(
                match: displayedMatch,
                stream: s,
                language: appState.language
            )
            guard generation == resolveGeneration else {
                fputs("[autoplay] discard stale resolve for \(s.displayName)\n", stderr)
                return
            }
            // Prefer the currently selected row if it is the same logical stream (detail may have refreshed).
            if let sel = selectedServer, sameStream(sel, s) {
                resolvedForServerId = sel.id
                resolvedForBackendStreamId = sel.backendStreamId ?? s.backendStreamId
            } else {
                resolvedForServerId = s.id
                resolvedForBackendStreamId = s.backendStreamId
            }
            resolvedPlaybackURL = resolved.url
            resolvedPlaybackHeaders = resolved.extraHTTPHeaders
            await refreshPlayerHTTPHeaders()
            guard generation == resolveGeneration else { return }
            isPlaying = true
            fputs("[autoplay] playing server=\(s.displayName) url=\(resolved.url.absoluteString.prefix(100))\n", stderr)
        } catch {
            guard generation == resolveGeneration else { return }
            streamError = error.localizedDescription
            playbackProbe = "failed"
            fputs("[autoplay] failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func refreshPlayerHTTPHeaders() async {
        if let url = playbackURL, FCTVStreamResolverClient.isProxiedPlayableURL(url) {
            playerHTTPHeaders = nil
            return
        }
        let ua = await RbliveHTTPClient.shared.rbPlaybackUserAgent()
        var merged: [String: String] = [:]
        if let extra = resolvedPlaybackHeaders, !extra.isEmpty {
            merged = extra
        }
        let needsRB = RbliveHlsInjectEngine.injectEnabled
            || (playbackURL?.absoluteString.contains("_sou") == true)
        if needsRB {
            for (k, v) in RbliveHlsInjectEngine.calcRBHeaders(rbUserAgent: ua) {
                if merged[k.lowercased()] == nil { merged[k] = v }
            }
        }
        if merged["user-agent"] == nil, merged["User-Agent"] == nil {
            merged["User-Agent"] = ua
        }
        if merged["referer"] == nil, merged["Referer"] == nil {
            // CTU / CDN segments need Referer or they die after the first live window (~30–45s).
            if let ref = UserDefaults.standard.string(forKey: "fctv.rblive.http_referer")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !ref.isEmpty {
                merged["Referer"] = ref
            } else {
                merged["Referer"] = "https://www.fctv33.com/"
            }
        }
        if let rb = await RbliveHTTPClient.shared.lastSessionHeader() {
            merged["rb-session"] = rb
        }
        playerHTTPHeaders = merged.isEmpty ? nil : merged
    }

    private func configureAudioSession() {
        do {
            // Same category as streamsports — required for background audio + system PiP.
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Best-effort on simulator / restricted routes.
        }
    }

    // MARK: - Live detail refresh (score + highlights)

    /// Poll `/api/match/detail` while the page stays open so score/clock/highlights stay fresh.
    private func startDetailAutoRefresh(immediate: Bool = false) {
        detailRefreshTask?.cancel()
        detailRefreshTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            while !Task.isCancelled {
                await refreshDisplayedMatch()
                // Streams may arrive only after `/api/match/detail` — one-shot autoplay, not on every poll.
                if awaitingInitialAutoplay {
                    if let preferred = PlaybackOpenShortcut.preferredServer(in: displayedMatch.streams) {
                        selectedServer = preferred
                    } else if selectedServer == nil {
                        selectedServer = displayedMatch.streams.first
                    }
                    if let server = selectedServer {
                        awaitingInitialAutoplay = false
                        didApplyAutoStartPlayback = true
                        await startPlayback(for: server)
                    }
                } else if !didRecoverAutoplayAfterDetail, serversHydratedFromDetail {
                    // List autoplay can finish against a row detail then replaces → playing with no URL.
                    if playbackURL != nil {
                        didRecoverAutoplayAfterDetail = true
                    } else if let server = selectedServer
                        ?? PlaybackOpenShortcut.preferredServer(in: displayedMatch.streams)
                        ?? displayedMatch.streams.first
                    {
                        didRecoverAutoplayAfterDetail = true
                        selectedServer = PlaybackOpenShortcut.preferredServer(in: displayedMatch.streams) ?? server
                        fputs("[autoplay] recover after detail for \(selectedServer?.displayName ?? "?")\n", stderr)
                        await startPlayback(for: selectedServer)
                    } else {
                        didRecoverAutoplayAfterDetail = true
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// Loads past + current timeline from `/api/match/event` (score-diff polling only sees events after open).
    private func loadHistoricalHighlights() async {
        let canFetch = appState.isActivated || UITestingConfiguration.skipActivationGate
        guard canFetch else { return }
        do {
            guard let rows = try await MatchService.shared.fetchMatchEvents(
                match: displayedMatch,
                language: appState.language,
                isActivated: true
            ), !rows.isEmpty else { return }
            highlights = Array(rows.prefix(40))
            fputs("[events] loaded \(rows.count) timeline rows for \(displayedMatch.id)\n", stderr)
        } catch {
            fputs("[events] failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func refreshDisplayedMatch() async {
        let canFetch = appState.isActivated || UITestingConfiguration.skipActivationGate
        guard canFetch else { return }
        do {
            guard let fresh = try await MatchService.shared.fetchMatchDetail(
                match: displayedMatch,
                language: appState.language,
                isActivated: true
            ) else { return }
            let previous = displayedMatch
            let merged = Self.mergeLiveRefresh(previous: previous, fresh: fresh)
            // Prefer full event timeline when available; fall back to score/status diffs.
            if let rows = try? await MatchService.shared.fetchMatchEvents(
                match: merged,
                language: appState.language,
                isActivated: true
            ), !rows.isEmpty {
                highlights = Array(rows.prefix(40))
            } else if let rows = Self.highlightsDiff(previous: previous, next: merged), !rows.isEmpty {
                highlights.insert(contentsOf: rows, at: 0)
                if highlights.count > 40 {
                    highlights = Array(highlights.prefix(40))
                }
            }
            displayedMatch = merged
            serversHydratedFromDetail = true
            // Prefer a reliably named server for selection / UI.
            let preferred = PlaybackOpenShortcut.preferredServer(in: merged.streams)
                ?? merged.streams.first(where: \.hasReliableChannelName)
                ?? merged.streams.first
            if let sel = selectedServer,
               let updated = merged.streams.first(where: {
                   $0.id == sel.id
                       || ($0.backendStreamId != nil && $0.backendStreamId != 0 && $0.backendStreamId == sel.backendStreamId)
               }) {
                // Adopt detail's stable id so playbackURL / resolve bookkeeping stay aligned.
                selectedServer = StreamServer(
                    id: updated.id,
                    name: updated.name,
                    fullName: updated.fullName,
                    playbackURL: sel.playbackURL ?? updated.playbackURL,
                    resolution: updated.resolution,
                    language: updated.language,
                    country: updated.country,
                    countryCode: updated.countryCode,
                    backendStreamId: updated.backendStreamId ?? sel.backendStreamId,
                    originalInfoWire: updated.originalInfoWire ?? sel.originalInfoWire,
                    backendSiteType: updated.backendSiteType ?? sel.backendSiteType
                )
                if resolvedForServerId == sel.id || resolvedForBackendStreamId == selectedServer?.backendStreamId {
                    resolvedForServerId = updated.id
                    resolvedForBackendStreamId = updated.backendStreamId ?? resolvedForBackendStreamId
                }
            } else if let preferred {
                selectedServer = preferred
            }
            fputs(
                "[detail-refresh] id=\(merged.id) score=\(merged.homeScore.map(String.init) ?? "-")-\(merged.awayScore.map(String.init) ?? "-") clock=\(merged.liveClock ?? "-") streams=\(merged.streams.count)\n",
                stderr
            )
        } catch {
            // Still unblock UI so we don't spin forever if detail fails.
            serversHydratedFromDetail = true
            fputs("[detail-refresh] failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func seedHighlights(for match: LiveMatch) -> [MatchHighlight] {
        var rows: [MatchHighlight] = []
        let kick = match.timeLabel
        rows.append(
            MatchHighlight(
                minute: match.liveClock ?? kick,
                text: "\(match.displayName) · kick-off \(kick)",
                kind: .info
            )
        )
        if let h = match.homeScore, let a = match.awayScore, h + a > 0 {
            rows.insert(
                MatchHighlight(
                    minute: match.liveClock ?? "",
                    text: "Score \(h)-\(a)",
                    kind: .status
                ),
                at: 0
            )
        }
        return rows
    }

    private static func mergeLiveRefresh(previous: LiveMatch, fresh: LiveMatch) -> LiveMatch {
        let streams: [StreamServer] = {
            if fresh.streams.isEmpty { return previous.streams }
            return fresh.streams.map { row in
                if let old = previous.streams.first(where: {
                    $0.id == row.id || ($0.backendStreamId != nil && $0.backendStreamId == row.backendStreamId)
                }), let kept = old.playbackURL {
                    return StreamServer(
                        id: row.id,
                        name: row.name,
                        fullName: row.fullName,
                        playbackURL: kept,
                        resolution: row.resolution,
                        language: row.language,
                        country: row.country,
                        countryCode: row.countryCode,
                        backendStreamId: row.backendStreamId,
                        originalInfoWire: row.originalInfoWire ?? old.originalInfoWire,
                        backendSiteType: row.backendSiteType
                    )
                }
                return row
            }
        }()
        return LiveMatch(
            id: fresh.id,
            sport: fresh.sport,
            leagueName: fresh.leagueName.isEmpty ? previous.leagueName : fresh.leagueName,
            leagueLogoURL: fresh.leagueLogoURL ?? previous.leagueLogoURL,
            leagueFlag: fresh.leagueFlag ?? previous.leagueFlag,
            region: fresh.region.isEmpty ? previous.region : fresh.region,
            contenders: fresh.meaningfulContenders.isEmpty ? previous.contenders : fresh.contenders,
            homeScore: fresh.homeScore ?? previous.homeScore,
            awayScore: fresh.awayScore ?? previous.awayScore,
            status: fresh.status,
            startDate: fresh.startDate,
            liveClock: fresh.liveClock ?? previous.liveClock,
            hot: fresh.hot,
            streams: streams
        )
    }

    private static func highlightsDiff(previous: LiveMatch, next: LiveMatch) -> [MatchHighlight]? {
        var rows: [MatchHighlight] = []
        let minute = next.liveClock ?? ""

        let ph = previous.homeScore ?? 0
        let pa = previous.awayScore ?? 0
        let nh = next.homeScore ?? 0
        let na = next.awayScore ?? 0
        if nh != ph || na != pa {
            let home = next.meaningfulContenders.first?.name ?? "Home"
            let away = next.meaningfulContenders.dropFirst().first?.name ?? "Away"
            let scorer: String
            if nh > ph {
                scorer = home
            } else if na > pa {
                scorer = away
            } else {
                scorer = next.displayName
            }
            rows.append(
                MatchHighlight(
                    minute: minute,
                    text: "Goal — \(scorer) · \(nh)-\(na)",
                    kind: .goal
                )
            )
        }

        if previous.status != next.status {
            let label: String
            if next.status.isFinished {
                label = "Full time · \(nh)-\(na)"
            } else if next.status == .secondHalf, previous.status != .secondHalf {
                label = "Second half underway"
            } else {
                label = "Status update"
            }
            rows.append(MatchHighlight(minute: minute.isEmpty ? "FT" : minute, text: label, kind: .status))
        }

        // Periodic clock pulse (every ~5') so the list doesn't stay frozen when score is static.
        if let clock = next.liveClock,
           clock != previous.liveClock,
           let m = Int(clock.filter(\.isNumber)),
           m > 0,
           m % 5 == 0,
           rows.isEmpty {
            rows.append(
                MatchHighlight(
                    minute: clock,
                    text: "Play continues · \(nh)-\(na)",
                    kind: .info
                )
            )
        }

        return rows.isEmpty ? nil : rows
    }
}

/// Reads the enclosing `UIScrollView.contentOffset` so pull-past-top is reliable (SwiftUI prefs are not).
private struct PlayerScrollOffsetReader: UIViewRepresentable {
    var onOffsetY: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffsetY: onOffsetY)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onOffsetY = onOffsetY
        context.coordinator.attachIfNeeded(from: uiView)
    }

    final class Coordinator {
        var onOffsetY: (CGFloat) -> Void
        private var observation: NSKeyValueObservation?
        private weak var observed: UIScrollView?

        init(onOffsetY: @escaping (CGFloat) -> Void) {
            self.onOffsetY = onOffsetY
        }

        func attachIfNeeded(from view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard let scroll = view.enclosingScrollView() else { return }
                if observed === scroll, observation != nil { return }
                observation?.invalidate()
                observed = scroll
                observation = scroll.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                    let adjusted = sv.contentOffset.y + sv.adjustedContentInset.top
                    DispatchQueue.main.async {
                        self?.onOffsetY(adjusted)
                    }
                }
            }
        }

        deinit {
            observation?.invalidate()
        }
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var current: UIView? = self
        while let view = current {
            if let scroll = view as? UIScrollView { return scroll }
            current = view.superview
        }
        return nil
    }
}

/// Width-driven 16:9 for portrait: height follows screen width.
/// Avoids `aspectRatio(..., .fit)` shrinking width when the parent VStack is short.
private struct PlayerAspectModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                // Keep ideal height from full width even if VStack proposes less height.
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content
        }
    }
}

#Preview {
    PlayerView(match: MatchServiceUITestSeed.previewMatch) {}
        .environment(AppState())
        .environment(PlaybackSession())
}

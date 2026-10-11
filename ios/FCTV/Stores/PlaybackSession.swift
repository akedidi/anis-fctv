import AVFoundation
import Foundation
import SwiftUI

/// Global mini-player / PiP session — keeps playback alive when leaving match detail.
/// Owns at most one active `AVPlayer` (streamsports `PlayerManager` pattern).
@MainActor
@Observable
final class PlaybackSession {
    var match: LiveMatch?
    var server: StreamServer?
    var playbackURL: URL?
    var httpHeaders: [String: String]?
    var isPlaying = false
    var isExpanded = false
    /// Mirrors `AVPlayer.isMuted` for the in-player mute button (not native AVKit chrome).
    var isMuted = false
    /// Hide the dock until detail `fullScreenCover` has finished dismissing (avoids black video).
    var dockSuppressed = false

    /// Sole live AVPlayer; replaced/stopped whenever the session changes event/stream.
    @ObservationIgnored
    private var activePlayer: AVPlayer?
    /// Retained for `rblivehls:` resource-loader pipelines while the player outlives a view.
    @ObservationIgnored
    private var retainedHlsLoader: RbliveHlsAssetLoader?

    /// Mini-player dock visible (hidden while detail is up, or until dismiss completes after minimize).
    var isActive: Bool {
        match != nil && playbackURL != nil && isPlaying && !isExpanded && !dockSuppressed
    }

    /// Shared pipeline for seamless detail ↔ mini hand-off (same URL).
    var boundPlayer: AVPlayer? { activePlayer }

    /// Bottom space lists/tabs should reserve while the mini-player is visible.
    var reservedBottomInset: CGFloat {
        isActive ? Theme.DockMetrics.contentInset : 0
    }

    /// Reuse the live `AVPlayer` when the UI surface changes (detail → mini → detail).
    func reusablePlayer(for url: URL) -> AVPlayer? {
        guard let activePlayer, let playbackURL, playbackURL == url else { return nil }
        return activePlayer
    }

    /// Register the player that is currently rendering this session (or full-screen hand-off).
    /// Previous player is paused and its item cleared — one audio/video pipeline at a time.
    func bindPlayer(_ player: AVPlayer, hlsLoader: RbliveHlsAssetLoader? = nil) {
        if activePlayer === player {
            if hlsLoader != nil { retainedHlsLoader = hlsLoader }
            isMuted = player.isMuted
            return
        }
        releaseActivePlayer(reason: "bind replacement")
        activePlayer = player
        retainedHlsLoader = hlsLoader
        player.isMuted = false
        isMuted = false
        fputs("[playbackSession] bound player=\(ObjectIdentifier(player)) muted=false\n", stderr)
    }

    func toggleMute() {
        guard let player = activePlayer else {
            isMuted.toggle()
            return
        }
        player.isMuted.toggle()
        isMuted = player.isMuted
        fputs("[playbackSession] muted=\(isMuted)\n", stderr)
    }

    func setMuted(_ muted: Bool) {
        activePlayer?.isMuted = muted
        isMuted = muted
    }

    /// Stop any active AVPlayer without clearing session metadata (e.g. pause button).
    func pauseActivePlayer() {
        activePlayer?.pause()
    }

    func adopt(
        match: LiveMatch,
        server: StreamServer?,
        url: URL,
        headers: [String: String]?
    ) {
        if let previous = self.match, previous.id != match.id {
            fputs(
                "[playbackSession] adopt replaces match \(previous.id) → \(match.id)\n",
                stderr
            )
            releaseActivePlayer(reason: "adopt other match")
        }
        self.match = match
        self.server = server
        self.playbackURL = url
        self.httpHeaders = headers
        self.isPlaying = true
        self.isExpanded = false
    }

    /// Begin minimize: keep session playing but suppress the dock until detail dismiss finishes.
    func minimize(
        match: LiveMatch,
        server: StreamServer?,
        url: URL?,
        headers: [String: String]?,
        playing: Bool
    ) {
        guard playing, let url else {
            stop()
            return
        }
        adopt(match: match, server: server, url: url, headers: headers)
        // Keep video on the detail surface during the cover dismiss animation.
        dockSuppressed = true
        isExpanded = false
    }

    /// Call from `fullScreenCover` `onDismiss` after a minimize handoff.
    func revealDockAfterDetailDismiss() {
        guard match != nil, playbackURL != nil, isPlaying else {
            dockSuppressed = false
            return
        }
        dockSuppressed = false
        fputs("[playbackSession] dock revealed after detail dismiss\n", stderr)
    }

    /// Opening another event while a mini-player (or orphan player) is active.
    func prepareForNewEvent(matchId: String) {
        guard let current = match else {
            if activePlayer != nil {
                releaseActivePlayer(reason: "prepare new event (orphan)")
            }
            return
        }
        if current.id != matchId {
            fputs(
                "[playbackSession] stop previous event \(current.id) before \(matchId)\n",
                stderr
            )
            stop()
        }
    }

    func stop() {
        releaseActivePlayer(reason: "stop")
        isPlaying = false
        isMuted = false
        playbackURL = nil
        httpHeaders = nil
        server = nil
        match = nil
        isExpanded = false
        dockSuppressed = false
        fputs("[playbackSession] stopped\n", stderr)
    }

    func expand() {
        isExpanded = true
        dockSuppressed = false
    }

    private func releaseActivePlayer(reason: String) {
        guard let player = activePlayer else {
            retainedHlsLoader = nil
            return
        }
        fputs(
            "[playbackSession] release player=\(ObjectIdentifier(player)) (\(reason))\n",
            stderr
        )
        player.pause()
        player.replaceCurrentItem(with: nil)
        activePlayer = nil
        retainedHlsLoader = nil
    }
}

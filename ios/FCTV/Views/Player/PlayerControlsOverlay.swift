import SwiftUI

/// In-player chrome: tap to show, auto-hide while playing.
/// Compact action cluster bottom-trailing (no duplicated fullscreen/zoom glyphs).
struct PlayerControlsOverlay: View {
    let title: String
    let isLandscape: Bool
    let isPlaying: Bool
    let isMuted: Bool
    let onPlayPause: () -> Void
    let onToggleMute: () -> Void
    let onTogglePiP: () -> Void
    let onToggleFullscreen: () -> Void
    /// User interacted — reset auto-hide timer.
    let onUserActivity: () -> Void
    let onRequestHide: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { onRequestHide() }

            // Center play/pause only.
            Button {
                onUserActivity()
                onPlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: isLandscape ? 56 : 48))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            VStack(spacing: 0) {
                if isLandscape {
                    HStack {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)
                    trailingControls
                }
                .padding(.horizontal, isLandscape ? 20 : 12)
                .padding(.bottom, isLandscape ? 20 : 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("player.controlsOverlay")
    }

    /// Single cluster: mute · AirPlay · PiP · fullscreen (zoom stays pinch-only).
    private var trailingControls: some View {
        HStack(spacing: 16) {
            controlIconButton(
                systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                identifier: "player.muteButton",
                label: isMuted ? "Unmute" : "Mute"
            ) {
                onUserActivity()
                onToggleMute()
            }

            AirPlayRouteButton()
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("player.airPlayButton")
                .accessibilityLabel("AirPlay")
                .simultaneousGesture(TapGesture().onEnded { onUserActivity() })

            controlIconButton(
                systemName: "pip.enter",
                identifier: "player.pipButton",
                label: "Picture in Picture",
                disabled: !isPlaying
            ) {
                onUserActivity()
                onTogglePiP()
            }

            // Sole enter/exit fullscreen control (zoom is pinch-only — no Fit/Fill button).
            controlIconButton(
                systemName: isLandscape ? "arrow.down.forward.and.arrow.up.backward" : "arrow.up.backward.and.arrow.down.forward",
                identifier: "player.fullscreenButton",
                label: isLandscape ? "Exit fullscreen" : "Fullscreen"
            ) {
                onUserActivity()
                onToggleFullscreen()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.45))
        )
    }

    private func controlIconButton(
        systemName: String,
        identifier: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}

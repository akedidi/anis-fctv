import SwiftUI

/// Compact bottom dock while a stream keeps playing outside the detail screen.
/// Layout/height aligned with streamsports `NuvioDockMetrics.miniPlayerHeight` (64).
struct MiniPlayerBar: View {
    @Environment(PlaybackSession.self) private var session
    let onExpand: () -> Void

    var body: some View {
        if session.isActive, let match = session.match {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 72, height: 44)
                    if let url = session.playbackURL {
                        HLSPlayerView(
                            url: url,
                            httpHeaders: session.httpHeaders,
                            isPlaying: Binding(
                                get: { session.isPlaying },
                                set: { playing in
                                    session.isPlaying = playing
                                    if !playing { session.pauseActivePlayer() }
                                }
                            ),
                            reusePlayer: session.reusablePlayer(for: url),
                            onPipelineReady: { player, loader in
                                session.bindPlayer(player, hlsLoader: loader)
                            }
                        )
                        .frame(width: 72, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                        // Stable id so SwiftUI does not recreate the representable (and hitch).
                        .id("mini-\(match.id)")
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(match.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if session.isPlaying {
                            Circle().fill(Theme.Colors.live).frame(width: 6, height: 6)
                            Text(session.server?.displayName ?? "Live")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button {
                    session.isPlaying.toggle()
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("miniPlayer.pause")

                Button {
                    session.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("miniPlayer.close")
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.DockMetrics.miniPlayerHeight)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.Colors.surfaceElevated.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 7)
            )
            .padding(.horizontal, Theme.DockMetrics.horizontalInset)
            .padding(.bottom, Theme.DockMetrics.bottomInset)
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            .accessibilityIdentifier("miniPlayer.bar")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

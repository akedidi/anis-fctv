import SwiftUI

/// Brand splash first (matches LaunchScreen — no loader), then the progress bar appears.
struct SplashView: View {
    @Environment(AppState.self) private var appState
    @State private var progress: Double = 0
    @State private var showLoader = false
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Theme.Colors.accent.opacity(glowPulse ? 0.22 : 0.1))
                            .frame(width: 168, height: 168)
                            .blur(radius: 28)
                            .scaleEffect(glowPulse ? 1.06 : 0.96)

                        Image("LaunchLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 108, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .shadow(color: Theme.Colors.accent.opacity(0.35), radius: 18, y: 10)
                    }
                    .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("FCTV33")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .tracking(4)

                        Capsule()
                            .fill(Theme.Colors.accent)
                            .frame(width: 72, height: 3)

                        Text("Live Sports · Anywhere")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .tracking(0.6)
                    }
                }

                Spacer()

                VStack(spacing: 14) {
                    if showLoader {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Theme.Colors.accent)
                            .frame(maxWidth: 168)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))

                        Text(versionLabel)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 48)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FCTV33")
        .task {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
            // Brand beat without loader (continues LaunchScreen).
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                showLoader = true
            }
            await runStartup()
        }
    }

    private func runStartup() async {
        for step in 1 ... 24 {
            try? await Task.sleep(nanoseconds: 55_000_000)
            progress = Double(step) / 24.0
        }
        appState.route = appState.isActivated ? .home : .activation
    }

    private var versionLabel: String {
        let dict = Bundle.main.infoDictionary
        let v = dict?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = dict?["CFBundleVersion"] as? String ?? "1"
        return "FCTV33  ·  v\(v) (\(b))"
    }
}

/// Stylized mark used when the bitmap asset is unavailable (previews / fallbacks).
struct FCTVLogo: View {
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Colors.accent, Color(hex: 0xFF6B01)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Theme.Colors.accent.opacity(0.4), radius: 12, y: 6)
            Image(systemName: "play.tv.fill")
                .font(.system(size: size * 0.5, weight: .black))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    SplashView().environment(AppState())
}

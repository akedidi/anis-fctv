import SwiftUI

/// Visual design tokens mirrored from the original Android app's colors/dimens.
///
/// Colors here match `res/values/colors.xml` from the source APK:
/// - background `#10182b`, header card `#242833`, accent `#ffae01`.
enum Theme {
    enum Colors {
        static let background = Color(hex: 0x10182B)
        static let surface = Color(hex: 0x1D2029)
        static let surfaceElevated = Color(hex: 0x242833)
        static let surfaceMuted = Color(hex: 0x343B4D)
        static let divider = Color(hex: 0x464B59)
        static let accent = Color(hex: 0xFFAE01)
        static let live = Color(hex: 0xE53935)
        static let success = Color(hex: 0x2EBB2E)
        /// Elapsed match minute (`76'`) on event cells — coral, not white/green/yellow.
        static let matchClock = Color(hex: 0xFF6F61)
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.6)
        static let textTertiary = Color.white.opacity(0.4)
        static let textMuted = Color(hex: 0x828A99)
        static let scoreMuted = Color.white.opacity(0.4)
        static let headerGradientStart = Color(hex: 0x1E2748)
        static let headerGradientEnd = Color(hex: 0x10182B)
        static let inputBackground = Color.white.opacity(0.08)
        static let inputBorder = Color.white.opacity(0.2)
    }

    enum Sizing {
        static let cornerSmall: CGFloat = 6
        static let cornerMedium: CGFloat = 10
        static let cornerLarge: CGFloat = 16
        static let cornerPill: CGFloat = 999
        static let teamLogo: CGFloat = 42
        static let teamLogoSmall: CGFloat = 28
        static let tabIcon: CGFloat = 44
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    /// Bottom dock metrics (mirrors streamsports `NuvioDockMetrics`).
    enum DockMetrics {
        static let horizontalInset: CGFloat = 16
        static let bottomInset: CGFloat = 8
        static let miniPlayerHeight: CGFloat = 64
        static let spacing: CGFloat = 8

        /// Extra scroll/list padding so rows never sit under the mini-player bar.
        static var contentInset: CGFloat {
            miniPlayerHeight + bottomInset + spacing
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension View {
    /// Card surface used for match rows and elevated panels.
    func cardSurface(_ color: Color = Theme.Colors.surface,
                     corner: CGFloat = Theme.Sizing.cornerMedium) -> some View {
        background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(color)
        )
    }

    /// Stroked pill used for filters and chips.
    func chipStyle(selected: Bool) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? Theme.Colors.accent : Color.white.opacity(0.08))
            )
            .foregroundStyle(selected ? Color.black : Theme.Colors.textPrimary)
    }
}

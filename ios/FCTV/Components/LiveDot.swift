import SwiftUI

/// Pulsing red dot used next to live matches and the "Live" filter chip.
struct LiveDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.Colors.live)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.0 : 0.6)
            .opacity(pulsing ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// Logo/flag bubble used in match rows and the detail header.
struct ContenderLogo: View {
    let contender: Contender
    var size: CGFloat = Theme.Sizing.teamLogo

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.Colors.surfaceElevated)
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
            if let url = contender.logoURL {
                RemoteLogo(url: url, size: size * 0.78, contentMode: .fit)
                    .padding(size * 0.11)
            } else if let flag = contender.flag {
                Text(flag).font(.system(size: size * 0.55))
            } else {
                Text(initials(contender.name))
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)) }.joined().uppercased()
    }
}

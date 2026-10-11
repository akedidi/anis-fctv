import SwiftUI

/// Compact stream server chips (flag + name), **2 per row** — same layout as Flutter mobile web.
struct ServerListView: View {
    let streams: [StreamServer]
    let selected: StreamServer?
    let onSelect: (StreamServer) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Servers")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.white)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(streams.enumerated()), id: \.element.id) { index, stream in
                    Button {
                        onSelect(stream)
                    } label: {
                        HStack(spacing: 8) {
                            flagView(for: stream)
                            Text(stream.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(stream == selected ? Theme.Colors.accent.opacity(0.18) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    stream == selected ? Theme.Colors.accent.opacity(0.55) : Color.white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(index == 0 ? "player.server.first" : "player.server.\(index)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.servers.section")
    }

    @ViewBuilder
    private func flagView(for stream: StreamServer) -> some View {
        // Prefer stored code; re-infer from channel label when missing (e.g. "TD EN", "Pam US").
        let code = stream.countryCode
            ?? CountryHelper.infer(fromStreamName: stream.displayName, matchRegion: stream.country).code
        if let code, let url = CountryHelper.flagCDNURL(for: code, width: 40) {
            RemoteLogo(url: url, size: 16, cornerRadius: 2)
                .frame(width: 22, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        } else if let code, let emoji = CountryHelper.flagEmoji(for: code) {
            Text(emoji)
                .font(.system(size: 14))
                .frame(width: 22, height: 16)
        } else {
            Image(systemName: "tv")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 22, height: 16)
        }
    }
}

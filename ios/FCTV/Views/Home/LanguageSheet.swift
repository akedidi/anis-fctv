import SwiftUI

/// Language picker sheet (mirrors the original `item_language` adapter).
struct LanguageSheet: View {
    let selectedID: String
    let onSelect: (AppLanguage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Language")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.top, Theme.Spacing.m)
                    .padding(.horizontal, Theme.Spacing.l)
                ForEach(AppLanguage.all) { language in
                    Button {
                        onSelect(language)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.nativeName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(language.englishName)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                            Spacer(minLength: 0)
                            if language.id == selectedID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // `.plain` only hits drawn text unless the whole row is a hit target.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().background(Color.white.opacity(0.05))
                }
            }
        }
        .background(Theme.Colors.surface)
    }
}

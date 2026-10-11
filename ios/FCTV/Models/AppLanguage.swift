import Foundation

/// Languages exposed in the in-app language picker.
///
/// Subset of the languages declared in the original strings table; the UI
/// strings themselves rely on iOS' built-in localization rather than swapping
/// locales manually.
struct AppLanguage: Identifiable, Hashable {
    let id: String
    let nativeName: String
    let englishName: String

    static let all: [AppLanguage] = [
        AppLanguage(id: "en", nativeName: "English", englishName: "English"),
        AppLanguage(id: "fr", nativeName: "Français", englishName: "French"),
        AppLanguage(id: "es", nativeName: "Español", englishName: "Spanish"),
        AppLanguage(id: "ar", nativeName: "العربية", englishName: "Arabic"),
        AppLanguage(id: "de", nativeName: "Deutsch", englishName: "German"),
        AppLanguage(id: "it", nativeName: "Italiano", englishName: "Italian"),
        AppLanguage(id: "pt", nativeName: "Português", englishName: "Portuguese"),
        AppLanguage(id: "pt-BR", nativeName: "Português do Brasil", englishName: "Brazilian Portuguese"),
        AppLanguage(id: "ru", nativeName: "Русский", englishName: "Russian"),
        AppLanguage(id: "tr", nativeName: "Türkçe", englishName: "Turkish"),
        AppLanguage(id: "nl", nativeName: "Nederlands", englishName: "Dutch"),
        AppLanguage(id: "pl", nativeName: "Polski", englishName: "Polish"),
        AppLanguage(id: "ro", nativeName: "Română", englishName: "Romanian"),
        AppLanguage(id: "el", nativeName: "Ελληνικά", englishName: "Greek"),
        AppLanguage(id: "bg", nativeName: "Български", englishName: "Bulgarian"),
        AppLanguage(id: "sr", nativeName: "Српски", englishName: "Serbian"),
        AppLanguage(id: "hu", nativeName: "Magyar", englishName: "Hungarian"),
        AppLanguage(id: "id", nativeName: "Bahasa Indonesia", englishName: "Indonesian"),
        AppLanguage(id: "ms", nativeName: "Bahasa Melayu", englishName: "Malay"),
        AppLanguage(id: "vi", nativeName: "Tiếng Việt", englishName: "Vietnamese"),
        AppLanguage(id: "th", nativeName: "ไทย", englishName: "Thai"),
        AppLanguage(id: "ko", nativeName: "한국어", englishName: "Korean"),
        AppLanguage(id: "ja", nativeName: "日本語", englishName: "Japanese"),
        AppLanguage(id: "zh-Hans", nativeName: "简体中文", englishName: "Chinese (Simplified)"),
        AppLanguage(id: "zh-Hant", nativeName: "繁體中文", englishName: "Chinese (Traditional)"),
        AppLanguage(id: "km", nativeName: "ភាសាខ្មែរ", englishName: "Khmer"),
        AppLanguage(id: "my", nativeName: "မြန်မာ", englishName: "Myanmar"),
    ]

    static let `default` = AppLanguage.all[0]
}

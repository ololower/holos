import Foundation
import whisper

/// Мова розпізнавання. Список береться з самого whisper, назви — українською з локалізації macOS.
struct DictationLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    static let auto = "auto"
    static let defaultCode = "uk"
    /// Показуються вгорі списку
    static let pinnedCodes = ["uk", "en"]

    static let all: [DictationLanguage] = {
        let locale = Locale(identifier: "uk_UA")
        return (0...whisper_lang_max_id()).compactMap { id -> DictationLanguage? in
            guard let raw = whisper_lang_str(id) else { return nil }
            let code = String(cString: raw)
            let english = whisper_lang_str_full(id).map { String(cString: $0) } ?? code
            // Для кодів, яких macOS не знає (наприклад, «jw»), лишаємо англійську назву з whisper
            let localized = locale.localizedString(forLanguageCode: code).flatMap { $0 == code ? nil : $0 }
            let name = localized ?? english
            return DictationLanguage(code: code, name: name.prefix(1).uppercased() + name.dropFirst())
        }
        .sorted { $0.name.compare($1.name, locale: locale) == .orderedAscending }
    }()

    static var pinned: [DictationLanguage] {
        pinnedCodes.compactMap { code in all.first { $0.code == code } }
    }

    static var others: [DictationLanguage] {
        all.filter { !pinnedCodes.contains($0.code) }
    }

    static func name(for code: String) -> String {
        if code == auto { return "Автовизначення" }
        return all.first { $0.code == code }?.name ?? code
    }
}

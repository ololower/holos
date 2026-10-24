import Foundation

/// Одне правило заміни: як модель пише фразу → як її треба писати. Порожнє `to` прибирає фразу.
struct ReplacementRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
}

/// Заміни в уже розпізнаному тексті — для слів, які whisper пише не так навіть із підказкою.
/// Сама модель про них не знає: Holos шукає фрази в її результаті й замінює.
/// Регістр у `from` не важить; замінюється лише ціле слово чи фраза, не шматок слова.
/// `to` вставляється як є; порожнє — прибирає фразу разом із зайвими комами.
struct Replacements {
    /// Лише правила з непорожнім `from`
    let rules: [ReplacementRule]
    private let compiled: [(NSRegularExpression, String)]

    init(_ rules: [ReplacementRule]) {
        self.rules = rules.compactMap { rule in
            let from = rule.from.trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : ReplacementRule(id: rule.id, from: from, to: rule.to.trimmingCharacters(in: .whitespaces))
        }
        compiled = self.rules.compactMap { rule in
            // Межі слова — будь-який символ, що не літера й не цифра (\b у ICU не завжди дружить з апострофом)
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: rule.from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: rule.to))
        }
    }

    /// Правила з тексту, по одному на рядок: «пі ейч пі шторм > PhpStorm». Для перевірки з командного
    /// рядка й перенесення старих налаштувань, де замість «>» була стрілка «→» чи «->».
    static func parse(_ text: String) -> [ReplacementRule] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            // Стрілки — першими: у «->» теж є «>»
            guard let separator = line.range(of: "→") ?? line.range(of: "->") ?? line.range(of: ">") else { return nil }
            return ReplacementRule(from: String(line[..<separator.lowerBound]), to: String(line[separator.upperBound...]))
        }
    }

    func apply(to text: String) -> String {
        var result = text
        for (regex, template) in compiled {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        if result != text && rules.contains(where: { $0.to.isEmpty }) {
            result = Self.tidy(result, capitalized: text.first?.isUppercase == true)
        }
        return result
    }

    /// Після видалення фрази: «відкрий, ну, файл» → «відкрий, , файл» → «відкрий, файл»
    private static func tidy(_ text: String, capitalized: Bool) -> String {
        var result = text
        for (pattern, template) in [
            ("[ \\t]{2,}", " "),           // подвійні пробіли
            ("[ \\t]+([,.!?;:])", "$1"),   // пробіл перед розділовим знаком
            (",(?:[ \\t]*,)+", ","),        // кілька ком підряд
            (",[ \\t]*([.!?;:])", "$1"),    // кома перед крапкою
            ("^[\\s,;:]+", ""),             // розділові знаки на початку
        ] {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        result = result.trimmingCharacters(in: .whitespaces)
        // Лишилися самі розділові знаки — вставляти нічого
        guard result.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        // Видалили перше слово речення — велика літера переходить до наступного
        if capitalized, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }
}

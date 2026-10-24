import Foundation

/// Заміни в розпізнаному тексті — для слів, які whisper пише не так навіть із підказкою.
/// По одному правилу на рядок: «пі ейч пі шторм → PhpStorm» (можна й «->»).
/// Регістр у лівій частині не важить; замінюється лише ціле слово чи фраза, не шматок слова.
/// Права частина вставляється як є; порожня — видаляє фразу.
struct Replacements {
    struct Rule {
        let from: String
        let to: String
    }

    let rules: [Rule]
    private let compiled: [(NSRegularExpression, String)]

    init(_ text: String) {
        rules = text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let arrow = line.range(of: "→") ?? line.range(of: "->") else { return nil }
            let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : Rule(from: from, to: to)
        }
        compiled = rules.compactMap { rule in
            // Межі слова — будь-який символ, що не літера й не цифра (\b у ICU не завжди дружить з апострофом)
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: rule.from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: rule.to))
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

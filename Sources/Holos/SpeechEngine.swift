import Foundation

/// Рушій розпізнавання. Не потокобезпечний: викликати з однієї послідовної черги.
protocol SpeechEngine: AnyObject {
    /// `path` — файл моделі (whisper) або тека з моделями Core ML (Parakeet)
    func load(path: String) throws
    func unload()
    /// Перше розпізнавання після завантаження повільніше — проганяємо секунду тиші заздалегідь
    func warmUp()
    /// `language` — код мови або «auto»; `prompt` і `options` кожен рушій використовує, наскільки вміє
    func transcribe(_ input: [Float], prompt: String, language: String, options: Transcriber.Options) -> String
}

enum SpeechEngineKind: String, CaseIterable, Identifiable {
    case whisper, parakeet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet (експериментально)"
        }
    }
}

extension Transcriber: SpeechEngine {}

import AppKit
import Combine

enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Правий ⌥ Option"
        case .rightCommand: return "Правий ⌘ Command"
        case .rightControl: return "Правий ⌃ Control"
        case .fn: return "fn / 🌐"
        }
    }

    var shortTitle: String {
        switch self {
        case .rightOption: return "правий ⌥"
        case .rightCommand: return "правий ⌘"
        case .rightControl: return "правий ⌃"
        case .fn: return "fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    // Біти конкретної (правої) клавіші з IOKit: NX_DEVICERALTKEYMASK тощо
    func isPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: return flags.rawValue & 0x40 != 0
        case .rightCommand: return flags.rawValue & 0x10 != 0
        case .rightControl: return flags.rawValue & 0x2000 != 0
        case .fn: return flags.contains(.function)
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holos/models", isDirectory: true)
    }

    static var defaultModelPath: String {
        // Повна large-v3 помітно точніша для української, ніж turbo; turbo — удвічі швидша
        modelsDirectory.appendingPathComponent("ggml-large-v3-q5_0.bin").path
    }

    private let defaults = UserDefaults.standard

    @Published var triggerKey: TriggerKey {
        didSet { defaults.set(triggerKey.rawValue, forKey: "triggerKey") }
    }

    /// Код мови whisper («uk», «en», …) або «auto»
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }

    /// UID мікрофона з CoreAudio; порожній рядок — системний за замовчуванням
    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: "microphoneUID") }
    }

    @Published var modelPath: String {
        didSet { defaults.set(modelPath, forKey: "modelPath") }
    }

    /// Підказка для whisper: імена, терміни, бажаний стиль
    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: "prompt") }
    }

    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: "playSounds") }
    }

    private init() {
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: "triggerKey") ?? "") ?? .rightOption
        language = defaults.string(forKey: "language") ?? DictationLanguage.defaultCode
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        modelPath = defaults.string(forKey: "modelPath") ?? Settings.defaultModelPath
        prompt = defaults.string(forKey: "prompt") ?? ""
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
    }
}

enum ModelState: Equatable {
    case loading
    case ready(loadSeconds: Double)
    case failed(String)
}

/// Стан, який показує вікно налаштувань
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    @Published var model: ModelState = .loading
    @Published var microphoneAllowed = false
    @Published var accessibilityAllowed = false
}

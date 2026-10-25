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

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holos", isDirectory: true)
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Тека Core ML-моделі Parakeet: ultra, якщо завантажена (точніша), інакше v3
    static var defaultParakeetModelPath: String {
        let ultra = modelsDirectory.appendingPathComponent("parakeet-ultra-coreml").path
        return FileManager.default.fileExists(atPath: ultra)
            ? ultra
            : modelsDirectory.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml").path
    }

    /// Скільки мікрофон лишається відкритим після диктування, якщо ввімкнено keepMicrophoneWarm
    static let warmMicrophoneSeconds = 10.0

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

    /// UID мікрофона з CoreAudio; порожній рядок — «Автоматично» (див. AudioDevices.resolve)
    @Published var microphoneUID: String {
        didSet {
            defaults.set(microphoneUID, forKey: "microphoneUID")
            // Назву запам'ятовуємо, щоб показати, який саме мікрофон від'єднано
            if let device = AudioDevices.inputs().first(where: { $0.uid == microphoneUID }) { microphoneName = device.name }
        }
    }

    @Published var microphoneName: String {
        didSet { defaults.set(microphoneName, forKey: "microphoneName") }
    }

    /// Підсилення в Holos, дБ, окремо для кожного мікрофона (UID → дБ). Застосовується до вже записаного
    /// звуку, тож системна гучність мікрофона й інші програми не змінюються.
    @Published var microphoneGains: [String: Double] {
        didSet { defaults.set(microphoneGains, forKey: "microphoneGains") }
    }

    static let gainRange: ClosedRange<Double> = -12...24

    func gain(for uid: String) -> Double {
        microphoneGains[uid] ?? 0
    }

    /// Подвійне натискання клавіші — запис без утримання
    @Published var handsFree: Bool {
        didSet { defaults.set(handsFree, forKey: "handsFree") }
    }

    // MARK: Експериментальне (див. ExperimentalPane): усе вимкнено за замовчуванням

    /// Не закривати мікрофон одразу після диктування, щоб наступне почалося миттєво
    @Published var keepMicrophoneWarm: Bool {
        didSet { defaults.set(keepMicrophoneWarm, forKey: "keepMicrophoneWarm") }
    }

    /// Після завантаження моделі розпізнати секунду тиші, щоб перше диктування не було повільнішим
    @Published var warmUpModel: Bool {
        didSet { defaults.set(warmUpModel, forKey: "experimentalWarmUp") }
    }

    /// Жадібне декодування замість beam search для фраз, довших за Transcriber.greedyAfterSeconds
    @Published var fastLongPhrases: Bool {
        didSet { defaults.set(fastLongPhrases, forKey: "experimentalFastLongPhrases") }
    }

    /// Без повторних спроб розпізнавання з вищою «температурою»
    @Published var noFallback: Bool {
        didSet { defaults.set(noFallback, forKey: "experimentalNoFallback") }
    }

    var transcriberOptions: Transcriber.Options {
        Transcriber.Options(fastLongPhrases: fastLongPhrases, noFallback: noFallback)
    }

    /// Заміни після розпізнавання (див. Replacements)
    @Published var replacementRules: [ReplacementRule] {
        didSet { defaults.set(try? JSONEncoder().encode(replacementRules), forKey: "replacementRules") }
    }

    var replacements: Replacements { Replacements(replacementRules) }

    /// Запускати Holos знову, якщо він аварійно завершився (див. Watchdog)
    @Published var restartAfterCrash: Bool {
        didSet { defaults.set(restartAfterCrash, forKey: "restartAfterCrash") }
    }

    /// Файл моделі whisper
    @Published var modelPath: String {
        didSet { defaults.set(modelPath, forKey: "modelPath") }
    }

    /// Рушій розпізнавання; Parakeet — експериментальний
    @Published var engine: SpeechEngineKind {
        didSet { defaults.set(engine.rawValue, forKey: "engine") }
    }

    @Published var parakeetModelPath: String {
        didSet { defaults.set(parakeetModelPath, forKey: "parakeetModelPath") }
    }

    /// Модель рушія, який зараз вибрано
    var activeModelPath: String {
        engine == .parakeet ? parakeetModelPath : modelPath
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
        microphoneName = defaults.string(forKey: "microphoneName") ?? ""
        microphoneGains = defaults.dictionary(forKey: "microphoneGains") as? [String: Double] ?? [:]
        modelPath = defaults.string(forKey: "modelPath") ?? Settings.defaultModelPath
        engine = SpeechEngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .whisper
        parakeetModelPath = defaults.string(forKey: "parakeetModelPath") ?? Settings.defaultParakeetModelPath
        prompt = defaults.string(forKey: "prompt") ?? ""
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        handsFree = defaults.object(forKey: "handsFree") as? Bool ?? true
        keepMicrophoneWarm = defaults.bool(forKey: "keepMicrophoneWarm")
        warmUpModel = defaults.bool(forKey: "experimentalWarmUp")
        fastLongPhrases = defaults.bool(forKey: "experimentalFastLongPhrases")
        noFallback = defaults.bool(forKey: "experimentalNoFallback")
        if let data = defaults.data(forKey: "replacementRules"),
           let rules = try? JSONDecoder().decode([ReplacementRule].self, from: data) {
            replacementRules = rules
        } else {
            // Раніше заміни були текстом «що → на що» по рядку
            let migrated = Replacements.parse(defaults.string(forKey: "replacements") ?? "")
            replacementRules = migrated
            defaults.set(try? JSONEncoder().encode(migrated), forKey: "replacementRules")
            defaults.removeObject(forKey: "replacements")
        }
        restartAfterCrash = defaults.object(forKey: "restartAfterCrash") as? Bool ?? true
        // Для мікрофона, вибраного до появи microphoneName
        if microphoneName.isEmpty, !microphoneUID.isEmpty,
           let device = AudioDevices.inputs().first(where: { $0.uid == microphoneUID }) {
            microphoneName = device.name
        }
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

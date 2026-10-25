import Foundation
import whisper

enum TranscriberError: LocalizedError {
    case fileNotFound(String)
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "Файл моделі не знайдено: \(path)"
        case .loadFailed: return "whisper не зміг завантажити модель"
        }
    }
}

/// Обгортка над whisper.cpp. Не потокобезпечна: викликати з однієї послідовної черги.
final class Transcriber {
    // Параметри розпізнавання. Вікно налаштувань показує саме ці значення.
    static let beamSize = 5
    static let vadPaddingMs = 200
    static let vadModelName = "Silero VAD v6.2.0"
    /// Скільки разів whisper за замовчуванням повторює розпізнавання з вищою «температурою» (0,2 … 1,0)
    static let fallbackRetries = 5

    /// Додаткові параметри (вкладка «Розпізнавання» → «Швидкість»)
    struct Options {
        /// Без повторних спроб: відповідь завжди швидка, але на поганому звуці текст може бути гіршим
        var noFallback = false
    }

    private var context: OpaquePointer?

    /// Типові «галюцинації» whisper на тиші й шумі — фрази із субтитрів, на яких він учився.
    /// Відкидаються лише тоді, коли це весь результат, а не частина реального тексту.
    static let hallucinations: Set<String> = [
        "дякую за перегляд", "дякуємо за перегляд", "субтитри",
        "thank you for watching", "thanks for watching",
    ]
    static let hallucinationMarkers = ["amara.org", "субтитри зроблен", "субтитри створ", "субтитрувальниц"]

    static let vadModelPath = Bundle.main.path(forResource: "ggml-silero-v6.2.0", ofType: "bin")

    init() {
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let context { whisper_free(context) }
    }

    var isLoaded: Bool { context != nil }

    /// Звільняє модель. Перед виходом обов'язково: інакше статичні деструктори ggml Metal під час exit()
    /// натрапляють на ще живі буфери й викликають abort() — кожен вихід ставав «аварійним».
    func unload() {
        if let context { whisper_free(context) }
        context = nil
    }

    func load(path: String) throws {
        if let context {
            whisper_free(context)
            self.context = nil
        }
        guard FileManager.default.fileExists(atPath: path) else { throw TranscriberError.fileNotFound(path) }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(path, params) else { throw TranscriberError.loadFailed }
        context = ctx
    }

    /// Перше розпізнавання після завантаження повільніше (~0,8 с на M1 Max): Metal готує конвеєри.
    /// Розпізнаємо секунду тиші, щоб це сталося одразу, а не на першому диктуванні.
    func warmUp() {
        guard let context else { return }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Self.threads
        params.no_context = true
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        let language = strdup("uk")
        defer { free(language) }
        params.language = UnsafePointer(language)
        // Без VAD: на тиші він пропустив би енкодер, а прогріти треба саме його
        let silence = [Float](repeating: 0, count: Int(AudioRecorder.sampleRate))
        _ = silence.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
    }

    private static var threads: Int32 {
        Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    /// `language` — код мови whisper або «auto» (тоді whisper визначає мову за першими 30 с)
    func transcribe(_ input: [Float], prompt: String, language: String, options: Options = Options()) -> String {
        guard let context, !input.isEmpty else { return "" }

        // Трохи тиші в кінці, щоб whisper не обрізав останнє слово, і мінімум 1 с загалом
        var samples = input + [Float](repeating: 0, count: Int(AudioRecorder.sampleRate * 0.3))
        let minimum = Int(AudioRecorder.sampleRate * 1.0)
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = Int32(Self.beamSize)
        if options.noFallback {
            // Лише одна спроба з температурою 0
            params.temperature_inc = 0
        }
        params.n_threads = Self.threads
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true

        let languageCode = strdup(language)
        defer { free(languageCode) }
        params.language = UnsafePointer(languageCode)
        params.detect_language = false // true означало б «лише визначити мову, без розпізнавання»

        // Silero VAD: whisper отримує лише фрагменти з мовленням, тож на тиші й шумі нічого не вигадує
        let vadPath = Self.vadModelPath.flatMap { strdup($0) }
        defer { free(vadPath) }
        if let vadPath {
            params.vad = true
            params.vad_model_path = UnsafePointer(vadPath)
            var vad = whisper_vad_default_params()
            vad.speech_pad_ms = Int32(Self.vadPaddingMs) // не обрізати тихі початки й кінці слів
            params.vad_params = vad
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPrompt = trimmedPrompt.isEmpty ? nil : strdup(trimmedPrompt)
        defer { free(initialPrompt) }
        params.initial_prompt = UnsafePointer(initialPrompt)

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard status == 0 else { return "" }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        return Self.clean(text)
    }

    /// Мова останнього розпізнавання (корисно для режиму «auto»)
    var lastLanguage: String? {
        guard let context else { return nil }
        return whisper_lang_str(whisper_full_lang_id(context)).map { String(cString: $0) }
    }

    /// Скільки токенів підказки модель бере: половина текстового контексту (448 / 2) мінус службовий токен.
    /// Довшу підказку whisper обрізає з початку.
    static let maxPromptTokens = 223

    func tokenCount(_ text: String) -> Int {
        guard let context else { return 0 }
        // З нульовим буфером whisper_tokenize повертає мінус потрібну кількість токенів
        return Int(abs(whisper_tokenize(context, text, nil, 0)))
    }

    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Позначки на кшталт [музика] чи (сміх) — не мовлення
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if hallucinations.contains(normalized) || hallucinationMarkers.contains(where: normalized.contains) {
            return ""
        }
        return text
    }

    /// Середньоквадратична гучність — відсікає записи, де нічого не сказано
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

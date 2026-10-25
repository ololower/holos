import CoreML
import Foundation

enum ParakeetError: LocalizedError {
    case missingFile(String)
    case badVocabulary
    case inference(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "У теці моделі Parakeet немає \(name) — завантажте її: scripts/download-model.sh parakeet-ultra"
        case .badVocabulary: return "Не вдалося прочитати словник Parakeet"
        case .inference(let message): return "Parakeet: \(message)"
        }
    }
}

/// Експериментальний рушій: NVIDIA Parakeet TDT 0.6B v3 або донавчена на ній parakeet-ultra, у Core ML.
///
/// Формат моделей — як у FluidAudio (FluidInference на Hugging Face): Preprocessor (мел-спектрограма) →
/// Encoder (фіксоване вікно 15 с → 188 кадрів по 80 мс) → TDT-декодування (Decoder + JointDecisionv3).
/// Декодування повторює FluidAudio (Apache 2.0), але без його мережевого коду й потокового режиму:
/// для диктування досить розпізнати готовий запис.
///
/// Мову модель визначає сама (25 європейських мов); вибрана в Holos мова лише зсуває вибір між
/// близькими варіантами — див. LanguageBias. Підказок Parakeet не підтримує: перевірено, що «прогнати»
/// текст через декодер перед розпізнаванням нічого не змінює — слова вибирає акустична частина.
final class ParakeetEngine: SpeechEngine {
    static let sampleRate = 16_000
    /// Фіксоване вікно енкодера: 15 с
    static let windowSamples = 240_000
    static let blankId = 8192
    /// Голова тривалості TDT: на скільки кадрів енкодера просунутися
    static let durationBins = [0, 1, 2, 3, 4]
    /// Запобіжник від зациклення на одному кадрі
    static let maxSymbolsPerFrame = 10
    static let requiredFiles = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                                "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]

    /// Тека містить усе потрібне для рушія
    static func isModelDirectory(_ path: String) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
    }

    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    /// Номер токена → шматок SentencePiece (пробіл на початку — початок слова)
    private var vocabulary: [String] = []

    func load(path: String) throws {
        unload()
        let directory = URL(fileURLWithPath: path)
        for file in Self.requiredFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            throw ParakeetError.missingFile(file)
        }
        // Як у FluidAudio: мел-спектрограма на процесорі, решта — на Neural Engine
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let neuralEngine = MLModelConfiguration()
        neuralEngine.computeUnits = .cpuAndNeuralEngine
        preprocessor = try MLModel(contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu)
        encoder = try MLModel(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: neuralEngine)
        decoder = try MLModel(contentsOf: directory.appendingPathComponent("Decoder.mlmodelc"), configuration: neuralEngine)
        joint = try MLModel(contentsOf: directory.appendingPathComponent("JointDecisionv3.mlmodelc"), configuration: neuralEngine)

        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard let pieces = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw ParakeetError.badVocabulary }
        vocabulary = [String](repeating: "", count: Self.blankId)
        for (key, piece) in pieces {
            guard let id = Int(key), vocabulary.indices.contains(id) else { continue }
            // У словнику FluidAudio «▁» уже замінено пробілом, але про всяк випадок
            vocabulary[id] = piece.replacingOccurrences(of: "\u{2581}", with: " ")
        }
    }

    func unload() {
        preprocessor = nil
        encoder = nil
        decoder = nil
        joint = nil
        vocabulary = []
    }

    func warmUp() {
        _ = transcribe([Float](repeating: 0, count: Self.sampleRate), prompt: "", language: "auto", options: Transcriber.Options())
    }

    func transcribe(_ input: [Float], prompt: String, language: String, options: Transcriber.Options) -> String {
        guard preprocessor != nil, !input.isEmpty else { return "" }
        let bias = LanguageBias(language: language)
        do {
            let text = try Self.segments(input).map { try decode($0, bias: bias) }.joined(separator: " ")
            return Transcriber.clean(text)
        } catch {
            Log.dictation.error("\(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    // MARK: - Довгі записи

    /// Запис, довший за вікно енкодера, ріжемо в найтихішому місці останніх 4 с кожного вікна:
    /// між реченнями є паузи, тож слово навпіл не розріжеться. Шматки розпізнаються окремо.
    static func segments(_ samples: [Float]) -> [ArraySlice<Float>] {
        let frame = sampleRate / 10 // 100 мс
        var result: [ArraySlice<Float>] = []
        var start = samples.startIndex
        while samples.endIndex - start > windowSamples {
            let searchEnd = start + windowSamples - frame
            var cut = searchEnd
            var quietest = Float.infinity
            for position in stride(from: searchEnd - 4 * sampleRate, through: searchEnd, by: frame / 2) {
                let energy = samples[position..<position + frame].reduce(0) { $0 + $1 * $1 }
                if energy < quietest {
                    quietest = energy
                    cut = position + frame / 2
                }
            }
            result.append(samples[start..<cut])
            start = cut
        }
        result.append(samples[start...])
        return result
    }

    // MARK: - Розпізнавання одного вікна

    private func decode(_ segment: ArraySlice<Float>, bias: LanguageBias?) throws -> String {
        guard let preprocessor, let encoder, let decoder, let joint else { return "" }

        // Мел-спектрограма й енкодер: вікно завжди 15 с, справжня довжина — окремо
        let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let audioPointer = audio.dataPointer.assumingMemoryBound(to: Float.self)
        audioPointer.initialize(repeating: 0, count: Self.windowSamples)
        segment.withUnsafeBufferPointer { audioPointer.update(from: $0.baseAddress!, count: $0.count) }
        let mel = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": audio,
            "audio_length": try Self.int32Array([Int32(segment.count)]),
        ]))
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": try Self.output(mel, "mel"),
            "mel_length": try Self.output(mel, "mel_length"),
        ]))
        let frames = try Self.output(encoded, "encoder")      // [1, 1024, 188]
        let frameCount = min(frames.shape[2].intValue, try Self.output(encoded, "encoder_length")[0].intValue)
        let channels = frames.shape[1].intValue
        let channelStride = frames.strides[1].intValue
        let timeStride = frames.strides[2].intValue
        let framePointer = frames.dataPointer.assumingMemoryBound(to: Float.self)

        // TDT: порожній токен — початок; непорожній оновлює декодер; тривалість каже, на скільки кадрів іти далі
        var state = try runDecoder(decoder, token: Self.blankId, h: nil, c: nil)
        let step = try MLMultiArray(shape: [1, NSNumber(value: channels), 1], dataType: .float32)
        let stepPointer = step.dataPointer.assumingMemoryBound(to: Float.self)
        let stepStride = step.strides[1].intValue
        var tokens: [Int] = []
        var time = 0
        var lastEmission = -1
        var emissionsHere = 0

        while time < frameCount {
            for channel in 0..<channels {
                stepPointer[channel * stepStride] = framePointer[channel * channelStride + time * timeStride]
            }
            let decision = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "encoder_step": step,
                "decoder_step": state.output,
            ]))
            var token = try Self.output(decision, "token_id")[0].intValue
            // Порожній токен не чіпаємо: інакше упередження вставляло б слова там, де мовчали
            if let bias, token != Self.blankId {
                token = try rerank(decision, bias: bias) ?? token
            }
            let bin = try Self.output(decision, "duration")[0].intValue
            var duration = Self.durationBins[min(max(bin, 0), Self.durationBins.count - 1)]

            if token == Self.blankId {
                time += max(duration, 1)
                continue
            }
            // Не випускати той самий кадр знову й знову, коли тривалість 0
            if duration == 0 && time == lastEmission && emissionsHere >= 1 { duration = 1 }
            tokens.append(token)
            state = try runDecoder(decoder, token: token, h: state.h, c: state.c)
            if time == lastEmission {
                emissionsHere += 1
            } else {
                lastEmission = time
                emissionsHere = 1
            }
            if emissionsHere >= Self.maxSymbolsPerFrame {
                time += 1
                emissionsHere = 0
                lastEmission = -1
            }
            time += duration
        }
        return detokenize(tokens)
    }

    private struct DecoderState {
        let output: MLMultiArray // [1, 640, 1]
        let h: MLMultiArray      // [2, 1, 640]
        let c: MLMultiArray
    }

    private func runDecoder(_ decoder: MLModel, token: Int, h: MLMultiArray?, c: MLMultiArray?) throws -> DecoderState {
        let zeros = { () throws -> MLMultiArray in
            let array = try MLMultiArray(shape: [2, 1, 640], dataType: .float32)
            array.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: array.count)
            return array
        }
        let result = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": try Self.int32Array([Int32(token)], shape: [1, 1]),
            "target_length": try Self.int32Array([1]),
            "h_in": try h ?? zeros(),
            "c_in": try c ?? zeros(),
        ]))
        return DecoderState(output: try Self.output(result, "decoder"),
                            h: try Self.output(result, "h_out"),
                            c: try Self.output(result, "c_out"))
    }

    /// Найкращий із 64 кандидатів з урахуванням мовного упередження
    private func rerank(_ decision: MLFeatureProvider, bias: LanguageBias) throws -> Int? {
        let ids = try Self.output(decision, "top_k_ids")
        let logits = try Self.output(decision, "top_k_logits")
        var best: (id: Int, score: Float)?
        for index in 0..<ids.count {
            let id = ids[index].intValue
            let logit = logits[index].floatValue
            let score = id == Self.blankId ? logit : bias.score(piece(id), logit: logit)
            guard let score else { continue }
            if best == nil || score > best!.score { best = (id, score) }
        }
        return best?.id
    }

    private func piece(_ token: Int) -> String {
        vocabulary.indices.contains(token) ? vocabulary[token] : ""
    }

    private func detokenize(_ tokens: [Int]) -> String {
        tokens.map(piece)
            .filter { !($0.hasPrefix("<") && $0.hasSuffix(">")) } // службові: <unk>, <|endoftext|>…
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    private static func output(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let array = provider.featureValue(for: name)?.multiArrayValue else { throw ParakeetError.inference("немає виходу \(name)") }
        return array
    }

    private static func int32Array(_ values: [Int32], shape: [NSNumber]? = nil) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape ?? [NSNumber(value: values.count)], dataType: .int32)
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
        return array
    }
}

/// Parakeet визначає мову сам і на коротких фразах плутає українську з російською: правильний
/// український варіант («і», «віт», «ді») зазвичай серед кандидатів, але трохи програє. Тому для
/// вибраної мови чужі літери заборонено, а для української ще й токени з «і ї є ґ» отримують бонус.
struct LanguageBias {
    /// Бонус до логіта для токенів із суто українськими літерами. Підібрано на тестових фразах:
    /// 2 виправляє «и перевер… на проде» → «і перевір… на проді» й не чіпає правильних «де», «ви», «дим»;
    /// 3 виправляє ще й «Привет», але вже міняє сказане «й» на «і».
    static let ukrainianBonus: Float = 2

    private let forbidden: (Unicode.Scalar) -> Bool
    private let favoured: (Unicode.Scalar) -> Bool
    private let bonus: Float

    /// Мови Parakeet з латинським письмом
    private static let latinLanguages: Set<String> = ["en", "de", "fr", "es", "it", "pt", "hr", "sl", "lv", "lt", "et",
                                                     "fi", "sv", "da", "nl", "pl", "cs", "sk", "hu", "ro", "mt"]

    /// nil — без упередження (автовизначення чи мова без однозначного набору літер)
    init?(language: String) {
        switch language {
        case "uk":
            // Латиницю дозволяємо: git, PhpStorm
            let russianOnly = Set("ыэъёЫЭЪЁ".unicodeScalars)
            let ukrainianOnly = Set("іїєґІЇЄҐ".unicodeScalars)
            forbidden = { russianOnly.contains($0) }
            favoured = { ukrainianOnly.contains($0) }
            bonus = Self.ukrainianBonus
        case "ru":
            let ukrainianOnly = Set("іїєґІЇЄҐ".unicodeScalars)
            forbidden = { ukrainianOnly.contains($0) }
            favoured = { _ in false }
            bonus = 0
        case let code where Self.latinLanguages.contains(code):
            forbidden = { (0x0400...0x04FF).contains($0.value) } // кирилиця
            favoured = { _ in false }
            bonus = 0
        default:
            return nil
        }
    }

    /// Оцінка кандидата; nil — заборонений
    func score(_ piece: String, logit: Float) -> Float? {
        let scalars = piece.unicodeScalars
        if scalars.contains(where: forbidden) { return nil }
        return scalars.contains(where: favoured) ? logit + bonus : logit
    }
}

import AppKit

// Агент launchd перевіряє, чи Holos не впав (див. Watchdog). Перш за все інше: цей процес
// ні за яких умов не повинен стати другою копією застосунку.
if Watchdog.isWatchdogProcess {
    exit(Watchdog.check())
}

// Режим перевірки без інтерфейсу:
// Holos --transcribe <аудіофайл> [--engine whisper|parakeet] [--model <шлях>] [--prompt <підказка>]
//       [--language <код|auto>] [--warmup] [--no-fallback]
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    func option(_ name: String) -> String? {
        guard let j = CommandLine.arguments.firstIndex(of: name), j + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[j + 1]
    }
    let flags = Set(CommandLine.arguments)
    let engine = SpeechEngineKind(rawValue: option("--engine") ?? "") ?? .whisper
    exit(SelfTest.run(file: CommandLine.arguments[i + 1],
                      engineKind: engine,
                      modelPath: option("--model") ?? (engine == .parakeet ? Settings.defaultParakeetModelPath : Settings.defaultModelPath),
                      prompt: option("--prompt") ?? "",
                      language: option("--language") ?? DictationLanguage.defaultCode,
                      options: Transcriber.Options(noFallback: flags.contains("--no-fallback")),
                      warmUp: flags.contains("--warmup")))
}

// Заміни й пробіли навколо тексту без розпізнавання:
// Holos --postprocess <текст> [--rules "що > на що"…] [--before <символ>] [--after <символ>]
// Без --rules — заміни з налаштувань.
if let i = CommandLine.arguments.firstIndex(of: "--postprocess"), i + 1 < CommandLine.arguments.count {
    func option(_ name: String) -> String? {
        guard let j = CommandLine.arguments.firstIndex(of: name), j + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[j + 1]
    }
    let replacements = option("--rules").map { Replacements(Replacements.parse($0)) } ?? Settings.shared.replacements
    exit(SelfTest.postprocess(CommandLine.arguments[i + 1], replacements: replacements,
                              before: option("--before"), after: option("--after")))
}

// Виправлення моделлю на локальному сервері: Holos --correct <текст> [--server <адреса>] [--model <назва>]
// Без --server і --model — з налаштувань.
if let i = CommandLine.arguments.firstIndex(of: "--correct"), i + 1 < CommandLine.arguments.count {
    func option(_ name: String) -> String? {
        guard let j = CommandLine.arguments.firstIndex(of: name), j + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[j + 1]
    }
    var config = Settings.shared.correctionConfig
    config.server = option("--server") ?? config.server
    config.model = option("--model") ?? config.model
    exit(SelfTest.correct(CommandLine.arguments[i + 1], config: config))
}

// Запис із мікрофона без інтерфейсу: Holos --record <секунди> [--microphone <UID>]
if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count,
   let seconds = TimeInterval(CommandLine.arguments[i + 1]) {
    let j = CommandLine.arguments.firstIndex(of: "--microphone")
    let uid = j.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
    exit(SelfTest.record(seconds: seconds, deviceUID: uid ?? Settings.shared.microphoneUID))
}

// Список мов, які підтримує whisper: Holos --languages
if CommandLine.arguments.contains("--languages") {
    DictationLanguage.all.forEach { print("\($0.code)\t\($0.name)") }
    exit(0)
}

// Знімки вкладок налаштувань у PNG: Holos --render-settings <тека>
if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
    exit(MainActor.assumeIsolated { SelfTest.renderSettings(to: CommandLine.arguments[i + 1]) })
}

// Кадри анімації в PNG для перевірки: Holos --render-overlay <файл.png>
if let i = CommandLine.arguments.firstIndex(of: "--render-overlay"), i + 1 < CommandLine.arguments.count {
    exit(MainActor.assumeIsolated { SelfTest.renderOverlay(to: CommandLine.arguments[i + 1]) })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

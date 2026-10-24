import AppKit

// Режим перевірки без інтерфейсу:
// Holos --transcribe <аудіофайл> [--model <шлях>] [--prompt <підказка>] [--language <код|auto>]
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    func option(_ name: String) -> String? {
        guard let j = CommandLine.arguments.firstIndex(of: name), j + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[j + 1]
    }
    exit(SelfTest.run(file: CommandLine.arguments[i + 1],
                      modelPath: option("--model") ?? Settings.defaultModelPath,
                      prompt: option("--prompt") ?? "",
                      language: option("--language") ?? DictationLanguage.defaultCode))
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

// Кадри анімації в PNG для перевірки: Holos --render-overlay <файл.png>
if let i = CommandLine.arguments.firstIndex(of: "--render-overlay"), i + 1 < CommandLine.arguments.count {
    exit(MainActor.assumeIsolated { SelfTest.renderOverlay(to: CommandLine.arguments[i + 1]) })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AppKit

// Режим перевірки без інтерфейсу: Holos --transcribe <аудіофайл> [--model <шлях>] [--prompt <підказка>]
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    func option(_ name: String) -> String? {
        guard let j = CommandLine.arguments.firstIndex(of: name), j + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[j + 1]
    }
    exit(SelfTest.run(file: CommandLine.arguments[i + 1],
                      modelPath: option("--model") ?? Settings.defaultModelPath,
                      prompt: option("--prompt") ?? ""))
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

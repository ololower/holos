import AppKit
import AVFoundation
import SwiftUI

/// Перевірка розпізнавання з файлу без інтерфейсу й мікрофона.
/// Аудіо проходить через той самий конвертер, що й запис із мікрофона.
enum SelfTest {
    static func run(file: String, modelPath: String, prompt: String, language: String,
                    options: Transcriber.Options = Transcriber.Options(), warmUp: Bool = false) -> Int32 {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: file))
        } catch {
            print("Не вдалося відкрити \(file): \(error.localizedDescription)")
            return 1
        }
        let format = audioFile.processingFormat
        guard let converter = AVAudioConverter(from: format, to: AudioRecorder.targetFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
        else {
            print("Не вдалося налаштувати конвертер для \(format)")
            return 1
        }
        converter.downmix = true

        var samples: [Float] = []
        while audioFile.framePosition < audioFile.length {
            do { try audioFile.read(into: buffer) } catch { break }
            if buffer.frameLength == 0 { break }
            samples += AudioRecorder.convert(buffer, with: converter)
        }
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        print(String(format: "Аудіо: %.1f с (%.0f Гц → 16000 Гц)", seconds, format.sampleRate))

        let transcriber = Transcriber()
        let loadStart = Date()
        do {
            try transcriber.load(path: modelPath)
        } catch {
            print(error.localizedDescription)
            return 1
        }
        print(String(format: "Модель завантажено за %.2f с", Date().timeIntervalSince(loadStart)))
        if warmUp {
            let warmStart = Date()
            transcriber.warmUp()
            print(String(format: "Прогріто за %.2f с", Date().timeIntervalSince(warmStart)))
        }

        if !prompt.isEmpty {
            print("Підказка: \(transcriber.tokenCount(prompt)) токенів з \(Transcriber.maxPromptTokens)")
        }
        let start = Date()
        let text = transcriber.transcribe(samples, prompt: prompt, language: language, options: options)
        let detected = language == DictationLanguage.auto ? ", визначено: \(transcriber.lastLanguage ?? "?")" : ""
        print(String(format: "Розпізнано за %.2f с (мова: %@%@):", Date().timeIntervalSince(start), language, detected))
        print(text)
        let replaced = Settings.shared.replacements.apply(to: text)
        if replaced != text {
            print("Після замін:")
            print(replaced)
        }
        return text.isEmpty ? 2 : 0
    }

    /// Те, що відбувається з текстом після whisper: заміни й пробіли за символами навколо курсора.
    /// `before`/`after` — символ перед і після курсора; «край» — початок чи кінець поля; без них — поле,
    /// яке не віддає цього через Accessibility.
    static func postprocess(_ text: String, replacements: Replacements, before: String?, after: String?) -> Int32 {
        print("Правил: \(replacements.rules.count)")
        let replaced = replacements.apply(to: text)
        print("Після замін: «\(replaced)»")
        func character(_ value: String?) -> Character? { value == "край" ? nil : value?.first }
        let around = before == nil && after == nil
            ? nil
            : TextInserter.Surroundings(before: character(before ?? "край"), after: character(after ?? "край"))
        print("Вставиться: «\(TextInserter.spaced(replaced, around: around))»")
        return 0
    }

    /// Запис із мікрофона без інтерфейсу — тим самим AudioRecorder, що й під час диктування.
    /// Мікрофон береться з налаштувань Holos, якщо не вказано інший.
    static func record(seconds: TimeInterval, deviceUID: String) -> Int32 {
        let recorder = AudioRecorder()
        var failure: String?
        recorder.onFailure = { failure = $0 }
        let device = AudioDevices.resolve(preferredUID: deviceUID)
        let mode = deviceUID.isEmpty ? "автоматично" : (device?.uid == deviceUID ? "вибраний" : "вибраний від'єднаний, замість нього")
        print("Мікрофон (\(mode)): \(device?.name ?? "немає")")
        recorder.start(deviceUID: deviceUID, gains: Settings.shared.microphoneGains)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))

        var samples: [Float]?
        recorder.stop { samples = $0 }
        while samples == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        if let failure {
            print("Помилка: \(failure)")
            return 1
        }
        let recorded = samples ?? []
        print(String(format: "Записано: %.2f с з %.1f с, RMS %.4f",
                     Double(recorded.count) / AudioRecorder.sampleRate, seconds, Transcriber.rms(recorded)))
        return recorded.isEmpty ? 2 : 0
    }

    /// Знімки кожної вкладки вікна налаштувань у PNG (вікно на мить з'являється за межами екрана)
    @MainActor
    static func renderSettings(to directory: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let controller = SettingsWindowController()
        guard let window = controller.window else { return 1 }
        for tab in SettingsWindowController.Tab.allCases {
            controller.select(tab)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            // Разом із заголовком і панеллю вкладок
            guard let frameView = window.contentView?.superview,
                  let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { return 1 }
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            let path = (directory as NSString).appendingPathComponent("settings-\(tab.rawValue).png")
            guard let png = bitmap.representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil
            else { return 1 }
            print("Збережено: \(path) (\(Int(window.frame.width))×\(Int(window.frame.height)))")
        }
        window.orderOut(nil)
        return 0
    }

    /// Аркуш із ключовими кадрами пігулки: (підпис, фази, коли змінилася остання, гучність, момент кадру)
    @MainActor
    static func renderOverlay(to path: String) -> Int32 {
        let frames: [(String, [OverlayPhase], TimeInterval, Float?, TimeInterval)] = [
            ("Запис — тиша", [.recording], -10, 0.0005, 0),
            ("Запис — говорите", [.recording], -10, 0.08, 0.02),
            ("Запис — інший момент", [.recording], -10, 0.08, 0.09),
            ("Запис без утримання", [.recording, .handsFree], -10, 0.08, 0.02),
            ("Перехід у розпізнавання", [.recording, .transcribing], 0, 0.08, 0.17),
            ("Розпізнавання", [.recording, .transcribing], -10, nil, 0.3),
            ("Розпізнавання +0,25 с", [.recording, .transcribing], -10, nil, 0.55),
            ("Готово", [.transcribing, .done], -10, nil, 0),
            ("Помилка запису", [.recording, .failed], -10, nil, 0),
        ]
        let rows = frames.map { label, phases, changedAt, rms, time -> (String, OverlayModel, TimeInterval) in
            let model = OverlayModel()
            phases.forEach { model.set($0, at: changedAt) }
            if let rms { model.push(rms: rms, at: 0) }
            return (label, model, time)
        }
        let sheet = VStack(alignment: .leading, spacing: 14) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 16) {
                    Text(rows[i].0).frame(width: 190, alignment: .leading)
                    OverlayPill(model: rows[i].1, time: rows[i].2)
                }
            }
        }
        .padding(24)
        .background(Color(white: 0.88))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil
        else { return 1 }
        print("Збережено: \(path)")
        return 0
    }
}

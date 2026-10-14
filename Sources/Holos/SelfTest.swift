import AppKit
import AVFoundation
import SwiftUI

/// Перевірка розпізнавання з файлу без інтерфейсу й мікрофона.
/// Аудіо проходить через той самий конвертер, що й запис із мікрофона.
enum SelfTest {
    static func run(file: String, modelPath: String, prompt: String, language: String) -> Int32 {
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

        if !prompt.isEmpty {
            print("Підказка: \(transcriber.tokenCount(prompt)) токенів з \(Transcriber.maxPromptTokens)")
        }
        let start = Date()
        let text = transcriber.transcribe(samples, prompt: prompt, language: language)
        let detected = language == DictationLanguage.auto ? ", визначено: \(transcriber.lastLanguage ?? "?")" : ""
        print(String(format: "Розпізнано за %.2f с (мова: %@%@):", Date().timeIntervalSince(start), language, detected))
        print(text)
        return text.isEmpty ? 2 : 0
    }

    /// Аркуш із ключовими кадрами пігулки: (підпис, фази, коли змінилася остання, гучність, момент кадру)
    @MainActor
    static func renderOverlay(to path: String) -> Int32 {
        let frames: [(String, [OverlayPhase], TimeInterval, Float?, TimeInterval)] = [
            ("Запис — тиша", [.recording], -10, 0.0005, 0),
            ("Запис — говорите", [.recording], -10, 0.08, 0.02),
            ("Запис — інший момент", [.recording], -10, 0.08, 0.09),
            ("Перехід у розпізнавання", [.recording, .transcribing], 0, 0.08, 0.17),
            ("Розпізнавання", [.recording, .transcribing], -10, nil, 0.3),
            ("Розпізнавання +0,25 с", [.recording, .transcribing], -10, nil, 0.55),
            ("Готово", [.transcribing, .done], -10, nil, 0),
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

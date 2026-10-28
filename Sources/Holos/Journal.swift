import Foundation

/// Журнал диктувань для аналізу помилок (Settings.keepJournal, за замовчуванням вимкнено): аудіо, яке чула
/// модель розпізнавання, і текст на кожному кроці — що вона розпізнала, що після замін, що після моделі ШІ.
/// Лише на цьому Mac, у вибраній теці (Settings.journalPath); щоб видалити все — видалити теку. Записане аудіо —
/// заодно й тест на справжньому голосі: будь-яку зміну (заміни, інструкції, іншу модель) можна прогнати через нього.
final class Journal {
    /// Одне диктування — рядок у journal.jsonl
    struct Entry: Encodable {
        /// Час запису; він же назва аудіофайлу в audio/
        let id: String
        let date: Date
        let audioSeconds: Double
        let engine: String
        let model: String
        let language: String
        let recognizeSeconds: Double
        /// Що видала модель розпізнавання
        let recognized: String
        /// Після замін
        let replaced: String
        /// Що зробила модель ШІ: «виправлено», «без змін» чи чому текст лишився як є; nil — вимкнена
        var correction: String?
        var correctionSeconds: Double?
        /// Що вставлено
        var inserted = ""
    }

    static var defaultDirectory: URL {
        Settings.supportDirectory.appendingPathComponent("Journal", isDirectory: true)
    }

    private static func file(in directory: URL) -> URL { directory.appendingPathComponent("journal.jsonl") }

    private let queue = DispatchQueue(label: "holos.journal", qos: .utility)

    static func id(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter.string(from: date)
    }

    /// У фоні: вставка тексту на диск не чекає. Аудіо — у `audio/<id>.wav`, текст — рядком у journal.jsonl
    func save(_ entry: Entry, samples: [Float], in directory: URL) {
        queue.async {
            do {
                let audio = directory.appendingPathComponent("audio", isDirectory: true)
                try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                try Self.wav(samples).write(to: audio.appendingPathComponent(entry.id + ".wav"))
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .sortedKeys
                var line = try encoder.encode(entry)
                line.append(0x0A)
                let file = Self.file(in: directory)
                if let handle = try? FileHandle(forWritingTo: file) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                    try handle.close()
                } else {
                    try line.write(to: file)
                }
            } catch {
                Log.app.error("Журнал диктувань: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Скільки диктувань записано в теці
    static func count(in directory: URL) -> Int {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// 16-бітний PCM WAV, моно, з частотою запису — так, як чула модель розпізнавання
    static func wav(_ samples: [Float]) -> Data {
        let rate = UInt32(AudioRecorder.sampleRate)
        let size = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + size)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(size)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}

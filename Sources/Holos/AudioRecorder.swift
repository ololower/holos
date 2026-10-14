import AVFoundation
import AudioToolbox

enum RecorderError: LocalizedError {
    case noInput
    case converter

    var errorDescription: String? {
        switch self {
        case .noInput: return "Мікрофон недоступний"
        case .converter: return "Не вдалося налаштувати перетворення аудіо"
        }
    }
}

/// Записує мікрофон у пам'ять як 16 кГц моно Float32 — формат, який очікує whisper.
/// На диск нічого не пишеться.
final class AudioRecorder {
    static let sampleRate = 16_000.0
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []

    /// Гучність кожної порції аудіо (RMS); викликається з аудіопотоку
    var onLevel: ((Float) -> Void)?

    var isRecording: Bool { engine != nil }

    func start(deviceUID: String) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if !deviceUID.isEmpty, let device = AudioDevices.device(uid: deviceUID), let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { NSLog("Holos: не вдалося вибрати мікрофон \(deviceUID): \(status)") }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else { throw RecorderError.converter }
        converter.downmix = true

        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let converted = AudioRecorder.convert(buffer, with: converter)
            self?.lock.withLock { self?.samples.append(contentsOf: converted) }
            self?.onLevel?(Transcriber.rms(converted))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Зупиняє запис і повертає записані семпли
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        return lock.withLock {
            let result = samples
            samples = []
            return result
        }
    }

    /// Перетворює буфер довільного формату в 16 кГц моно. Конвертер зберігає стан між викликами,
    /// тому послідовні буфери стикуються без розривів.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

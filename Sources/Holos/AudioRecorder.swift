import AVFoundation
import CoreMedia

enum RecorderError: LocalizedError {
    case noInput
    case cannotOpen(String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noInput: return "Мікрофон недоступний"
        case .cannotOpen(let name): return "Не вдалося відкрити мікрофон «\(name)»"
        case .noAudio: return "Мікрофон не передає звук"
        }
    }
}

/// Записує мікрофон у пам'ять як 16 кГц моно Float32 — формат, який очікує whisper.
/// На диск нічого не пишеться.
///
/// AVCaptureSession, а не AVAudioEngine: сесія відкриває одразу вибраний мікрофон. AVAudioEngine спершу
/// підключається до системного мікрофона й лише потім перемикається на вибраний. Коли системним були
/// Bluetooth-навушники, це вмикало в них режим гарнітури, а розбіжність частот закінчувалася винятком
/// в installTap, якого Swift не ловить: запис мовчки не починався, а рушій лишався в пам'яті.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate = 16_000.0
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    /// Якщо за цей час після запуску не прийшло жодної порції звуку, мікрофон не працює
    static let noAudioTimeout = 1.5

    /// Гучність кожної порції аудіо (RMS); викликається з аудіопотоку
    var onLevel: ((Float) -> Void)?
    /// Запис зірвався; викликається з головного потоку й лише поки запис триває
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    /// startRunning і stopRunning блокують, тому вся робота із сесією — лише в цій черзі
    private let sessionQueue = DispatchQueue(label: "holos.capture")
    private let bufferQueue = DispatchQueue(label: "holos.capture.buffers", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    // Спільне для черг сесії й аудіо — під lock
    private let lock = NSLock()
    private var samples: [Float] = []
    private var isCollecting = false
    private var receivedAudio = false
    /// Підсилення Holos для поточного мікрофона, у разах (див. Settings.microphoneGains)
    private var gain: Float = 1

    /// Лише в bufferQueue: на випадок, якщо сесія віддасть не той формат, який просили
    private var converter: AVAudioConverter?

    // Лише в головному потоці
    private var generation = 0
    private var isRecording = false

    override init() {
        super.init()
        // Сесія сама перетворює звук у формат whisper
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: bufferQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            let message = error?.localizedDescription ?? "Мікрофон перестав працювати"
            Log.audio.error("Сесія запису: \(message, privacy: .public)")
            self?.fail(message)
        })
    }

    /// Відкриває мікрофон із цим UID; порожній чи від'єднаний — за чергою з AudioDevices.resolve.
    /// Повертається одразу: сесія запускається у фоні, помилки приходять в onFailure.
    /// `gains` — підсилення в дБ за UID мікрофона; береться для того, який справді відкриється
    func start(deviceUID: String, gains: [String: Double] = [:]) {
        generation += 1
        isRecording = true
        let generation = generation
        sessionQueue.async { [self] in
            // Тут, а не в головному потоці: попередній stop() у цій черзі має встигнути забрати свої семпли
            lock.withLock {
                samples.removeAll(keepingCapacity: true)
                isCollecting = true
                receivedAudio = false
            }
            do {
                guard let device = AudioDevices.resolve(preferredUID: deviceUID) else { throw RecorderError.noInput }
                if !deviceUID.isEmpty && device.uid != deviceUID {
                    Log.audio.notice("Вибраний мікрофон від'єднаний, беру «\(device.name, privacy: .public)»")
                }
                setGain(decibels: gains[device.uid] ?? 0)
                try attachDevice(device)
                session.startRunning()
                Log.audio.info("Мікрофон «\(device.name, privacy: .public)» відкрито")
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription, generation: generation) }
                return
            }
            sessionQueue.asyncAfter(deadline: .now() + Self.noAudioTimeout) { [self] in
                guard lock.withLock({ isCollecting && !receivedAudio }) else { return }
                DispatchQueue.main.async { self.fail(RecorderError.noAudio.localizedDescription, generation: generation) }
            }
        }
    }

    /// Зупиняє запис і віддає записані семпли в головний потік
    func stop(_ completion: @escaping ([Float]) -> Void) {
        isRecording = false
        sessionQueue.async { [self] in
            session.stopRunning()
            bufferQueue.sync {} // порції, які вже в дорозі
            let result = lock.withLock {
                isCollecting = false
                defer { samples = [] }
                return samples
            }
            detachDevice()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Лише в головному потоці. Без `generation` — про поточний запис.
    private func fail(_ message: String, generation: Int? = nil) {
        guard isRecording, generation == nil || generation == self.generation else { return }
        onFailure?(message)
    }

    /// Лише в sessionQueue
    private func attachDevice(_ device: AudioInputDevice) throws {
        guard let capture = AVCaptureDevice(uniqueID: device.uid) else { throw RecorderError.cannotOpen(device.name) }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: capture)
        } catch {
            throw RecorderError.cannotOpen(device.name)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { throw RecorderError.cannotOpen(device.name) }
        session.addInput(input)
    }

    /// Лише в sessionQueue. Між записами мікрофон не тримаємо.
    private func detachDevice() {
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    /// Можна міняти й під час запису — так повзунок у налаштуваннях діє одразу
    func setGain(decibels: Double) {
        let linear = Float(pow(10, decibels / 20))
        lock.withLock { gain = linear }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Порції, що прийшли вже після stop(), не обробляємо
        guard lock.withLock({ isCollecting }) else { return }
        var chunk = convert(sampleBuffer)
        let gain = lock.withLock { self.gain }
        if gain != 1 {
            // Як і справжній перевантажений мікрофон, не виходимо за ±1
            for i in chunk.indices { chunk[i] = max(-1, min(1, chunk[i] * gain)) }
        }
        let collecting = lock.withLock { () -> Bool in
            guard isCollecting else { return false }
            samples.append(contentsOf: chunk)
            receivedAudio = true
            return true
        }
        if collecting { onLevel?(Transcriber.rms(chunk)) }
    }

    /// Порція із сесії як 16 кГц моно. Зазвичай вона вже в цьому форматі (див. audioSettings),
    /// інакше — через AVAudioConverter.
    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let description = sampleBuffer.formatDescription else { return [] }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                   into: buffer.mutableAudioBufferList)
        guard status == noErr else { return [] }

        if format.commonFormat == .pcmFormatFloat32, format.sampleRate == Self.sampleRate, format.channelCount == 1,
           let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(frames)))
        }
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: Self.targetFormat)
            converter?.downmix = true
        }
        guard let converter else { return [] }
        return Self.convert(buffer, with: converter)
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

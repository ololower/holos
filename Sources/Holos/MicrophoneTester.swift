import Foundation

/// Кнопка «Перевірити» на вкладці «Мікрофон»: кілька секунд слухає мікрофон тим самим AudioRecorder,
/// що й диктування (з підсиленням Holos), показує рівень і каже, чи гучності досить
final class MicrophoneTester: ObservableObject {
    enum Verdict: Equatable {
        case quiet, low, good, clipping
        case failed(String)

        var text: String {
            switch self {
            case .quiet: return "Майже не чути — додайте підсилення або говоріть ближче до мікрофона"
            case .low: return "Тихувато — можна додати кілька дБ"
            case .good: return "Гучність добра"
            case .clipping: return "Перевантаження: звук спотворюється — зменште підсилення"
            case .failed(let message): return message
            }
        }

        var isProblem: Bool { self != .good }
    }

    static let duration: TimeInterval = 5

    @Published private(set) var isRunning = false
    /// Рівень для індикатора, 0…1 (−60…0 дБ)
    @Published private(set) var level = 0.0
    @Published private(set) var verdict: Verdict?

    private let recorder = AudioRecorder()
    private var loudestChunk: Float = 0
    private var autoStop: DispatchWorkItem?

    init() {
        recorder.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.push(rms) }
        }
        recorder.onFailure = { [weak self] message in
            self?.stop()
            self?.verdict = .failed(message)
        }
    }

    func start(deviceUID: String, gains: [String: Double]) {
        guard !isRunning else { return }
        verdict = nil
        loudestChunk = 0
        level = 0
        isRunning = true
        recorder.start(deviceUID: deviceUID, gains: gains)
        let stop = DispatchWorkItem { [weak self] in self?.stop() }
        autoStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: stop)
    }

    func setGain(decibels: Double) {
        recorder.setGain(decibels: decibels)
    }

    func stop() {
        guard isRunning else { return }
        autoStop?.cancel()
        isRunning = false
        level = 0
        recorder.stop { [weak self] samples in self?.evaluate(samples) }
    }

    private func push(_ rms: Float) {
        guard isRunning else { return }
        loudestChunk = max(loudestChunk, rms)
        let decibels = 20 * log10(max(Double(rms), 1e-6))
        let normalized = min(1, max(0, (decibels + 60) / 60))
        // Миттєва атака, плавне згасання
        level = max(normalized, level * 0.85)
    }

    /// Пороги — для мовлення: тиша в кімнаті з типовим USB-мікрофоном близько −42 дБ
    private func evaluate(_ samples: [Float]) {
        guard verdict == nil, !samples.isEmpty else { return }
        let clipped = samples.lazy.filter { abs($0) >= 0.99 }.count
        let loudest = 20 * log10(max(Double(loudestChunk), 1e-6))
        if Double(clipped) / Double(samples.count) > 0.001 {
            verdict = .clipping
        } else if loudest < -38 {
            verdict = .quiet
        } else if loudest < -28 {
            verdict = .low
        } else {
            verdict = .good
        }
    }
}

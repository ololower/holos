import AppKit

/// Клавіша-модифікатор для диктування.
/// - Тримати — запис; відпустити — вставити текст.
/// - Двічі коротко натиснути — запис без утримання; ще одне натискання — вставити, Esc — скасувати.
///
/// Під час утримання будь-яка інша клавіша скасовує запис — так не заважаємо звичайним комбінаціям
/// із цим модифікатором і даємо змогу скасувати через Esc. Без утримання інші клавіші не заважають:
/// руки вільні, можна перемикатися між вікнами.
final class HotkeyMonitor {
    var key: TriggerKey = .rightOption {
        didSet { reset(notify: true) }
    }
    /// Чи вмикати запис без утримання подвійним натисканням
    var handsFreeEnabled = true

    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHandsFree: (() -> Void)?

    /// Коротше — це натискання, а не утримання (можливо, перше з подвійного)
    static let tapDuration = 0.3
    /// Скільки чекати на друге натискання
    static let doubleTapWindow = 0.35
    private static let escapeKeyCode: UInt16 = 53

    private enum State {
        case idle
        case holding(since: Date)
        /// Коротко натиснули й відпустили: запис іще йде, чекаємо на друге натискання
        case tapped
        case handsFree
        /// Натиснули, щоб завершити запис без утримання; чекаємо, доки відпустять
        case finishing
    }

    private var state = State.idle
    private var keyIsDown = false
    private var tapTimer: Timer?
    private var monitors: [Any] = []

    /// Глобальні монітори працюють лише з дозволом Accessibility; після його надання їх треба перевстановити
    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Запис закінчився не через клавішу (помилка, обмеження тривалості)
    func reset() {
        reset(notify: false)
    }

    private func reset(notify: Bool) {
        let wasActive: Bool
        if case .idle = state { wasActive = false } else { wasActive = true }
        tapTimer?.invalidate()
        state = .idle
        if notify && wasActive { onCancel?() }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            switch state {
            case .holding, .tapped:
                cancel()
            case .handsFree where event.keyCode == Self.escapeKeyCode:
                cancel()
            default:
                break
            }
            return
        }
        guard event.keyCode == key.keyCode else {
            // Інший модифікатор під час утримання — це комбінація, а не диктування
            switch state {
            case .holding, .tapped: cancel()
            default: break
            }
            return
        }

        let pressed = key.isPressed(event.modifierFlags)
        if pressed && !keyIsDown {
            keyIsDown = true
            keyPressed()
        } else if !pressed && keyIsDown {
            keyIsDown = false
            keyReleased()
        }
    }

    private func keyPressed() {
        switch state {
        case .idle:
            state = .holding(since: Date())
            onStart?()
        case .tapped:
            tapTimer?.invalidate()
            state = .handsFree
            onHandsFree?()
        case .handsFree:
            state = .finishing
            onFinish?()
        case .holding, .finishing:
            break
        }
    }

    private func keyReleased() {
        switch state {
        case .holding(let since):
            if handsFreeEnabled && Date().timeIntervalSince(since) < Self.tapDuration {
                state = .tapped
                tapTimer = Timer.scheduledTimer(withTimeInterval: Self.doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self, case .tapped = self.state else { return }
                    self.cancel()
                }
            } else {
                state = .idle
                onFinish?()
            }
        case .finishing:
            state = .idle
        case .idle, .tapped, .handsFree:
            break
        }
    }

    private func cancel() {
        tapTimer?.invalidate()
        state = .idle
        onCancel?()
    }
}

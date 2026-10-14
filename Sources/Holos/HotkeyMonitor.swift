import AppKit

/// Стежить за натисканням і відпусканням однієї клавіші-модифікатора (push-to-talk).
/// Будь-яка інша клавіша під час утримання скасовує запис — так не заважаємо звичайним
/// комбінаціям із цим модифікатором і даємо змогу скасувати через Esc.
final class HotkeyMonitor {
    var key: TriggerKey = .rightOption {
        didSet { if isDown { isDown = false; onCancel?() } }
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

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

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            cancelIfHolding()
            return
        }
        guard event.keyCode == key.keyCode else {
            // Інший модифікатор під час утримання — це комбінація, а не диктування
            cancelIfHolding()
            return
        }
        let pressed = key.isPressed(event.modifierFlags)
        if pressed && !isDown {
            isDown = true
            onPress?()
        } else if !pressed && isDown {
            isDown = false
            onRelease?()
        }
    }

    private func cancelIfHolding() {
        guard isDown else { return }
        isDown = false
        onCancel?()
    }
}

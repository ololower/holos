import AppKit
import SwiftUI

/// Плаваюча пігулка внизу екрана. Не активується й не перехоплює фокус і мишу —
/// інакше ⌘V потрапив би не в те вікно.
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var pendingHide: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(_ phase: OverlayPhase) {
        pendingHide?.cancel()
        if !panel.isVisible {
            moveToActiveScreen()
            panel.orderFrontRegardless()
        }
        model.set(phase)
    }

    func hide(after delay: TimeInterval = 0) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.set(.hidden)
            // Даємо анімації зникнення завершитися
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.model.phase == .hidden { self.panel.orderOut(nil) }
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Екран, на якому зараз курсор миші, — над Dock, по центру
    private func moveToActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 12))
    }
}

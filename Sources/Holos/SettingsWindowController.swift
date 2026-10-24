import AppKit
import SwiftUI

/// Вікно налаштувань у стилі macOS: вкладки з іконками на панелі інструментів,
/// вікно підлаштовує висоту під вкладку
final class SettingsWindowController: NSWindowController {
    enum Tab: Int, CaseIterable {
        case general, microphone, recognition, experimental
    }

    private let tabs = SettingsTabViewController()

    init() {
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func select(_ tab: Tab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    /// Показує вікно по центру екрана, на якому зараз курсор
    func show(_ tab: Tab? = nil) {
        guard let window else { return }
        if let tab { select(tab) }
        if !window.isVisible {
            // Стандартний center() ставить вікно вище середини
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                let area = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsTabViewController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        addPane("Загальні", symbol: "gearshape", GeneralPane())
        addPane("Мікрофон", symbol: "mic", MicrophonePane())
        addPane("Розпізнавання", symbol: "waveform", RecognitionPane())
        addPane("Експериментальне", symbol: "flask", ExperimentalPane())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func addPane<Pane: View>(_ title: String, symbol: String, _ pane: Pane) {
        let controller = NSHostingController(rootView: pane)
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let window = view.window, let size = tabViewItem?.viewController?.preferredContentSize, size != .zero else { return }
        // Верхній край лишається на місці, як у системних налаштуваннях
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

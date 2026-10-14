import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Phase { case idle, recording, transcribing }

    private let settings = Settings.shared
    private let status = AppStatus.shared
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private lazy var overlay = OverlayController()
    /// Уся робота з whisper — лише в цій черзі
    private let work = DispatchQueue(label: "holos.whisper", qos: .userInitiated)

    private var statusItem: NSStatusItem!
    private let stateMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let copyLastMenuItem = NSMenuItem(title: "Копіювати останній текст", action: #selector(copyLast), keyEquivalent: "")
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var maxDurationTimer: Timer?

    private var phase = Phase.idle { didSet { updateStatusItem() } }
    private var recordingStartedAt = Date()
    private var lastText = ""

    private let minimumDuration = 0.3  // коротше — випадкове натискання
    private let maximumDuration = 180.0 // запобіжник, якщо подія відпускання загубилася
    private let silenceRMS: Float = 0.003

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        hotkey.key = settings.triggerKey
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.start()

        recorder.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.overlay.model.push(rms: rms) }
        }

        settings.$triggerKey.dropFirst().sink { [weak self] key in
            self?.hotkey.key = key
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &cancellables)

        settings.$modelPath.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] path in self?.loadModel(path: path) }
            .store(in: &cancellables)

        status.$model.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &cancellables)

        loadModel(path: settings.modelPath)
        setupPermissions()
    }

    // MARK: - Дозволи

    private func setupPermissions() {
        refreshPermissions()
        if !Permissions.microphoneAllowed {
            Permissions.requestMicrophone { [weak self] _ in self?.refreshPermissions() }
        }
        if !Permissions.accessibilityAllowed {
            Permissions.requestAccessibility()
        }
        if !Permissions.microphoneAllowed || !Permissions.accessibilityAllowed {
            openSettings()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    private func refreshPermissions() {
        let accessibility = Permissions.accessibilityAllowed
        if accessibility && !status.accessibilityAllowed {
            // Глобальні монітори, встановлені без дозволу, мовчать — перевстановлюємо
            hotkey.start()
        }
        if status.accessibilityAllowed != accessibility {
            status.accessibilityAllowed = accessibility
            NSLog("Holos: універсальний доступ = %@", accessibility ? "так" : "ні")
        }
        let microphone = Permissions.microphoneAllowed
        if status.microphoneAllowed != microphone {
            status.microphoneAllowed = microphone
            NSLog("Holos: мікрофон = %@", microphone ? "так" : "ні")
        }
        updateStatusItem()
    }

    // MARK: - Модель

    private func loadModel(path: String) {
        status.model = .loading
        work.async { [transcriber, status] in
            let start = Date()
            do {
                try transcriber.load(path: path)
                let seconds = Date().timeIntervalSince(start)
                DispatchQueue.main.async { status.model = .ready(loadSeconds: seconds) }
            } catch {
                DispatchQueue.main.async { status.model = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Диктування

    private func startRecording() {
        guard phase == .idle else { return }
        guard case .ready = status.model else {
            NSSound.beep()
            return
        }
        do {
            try recorder.start(deviceUID: settings.microphoneUID)
        } catch {
            NSLog("Holos: запис не почався: \(error.localizedDescription)")
            NSSound.beep()
            return
        }
        recordingStartedAt = Date()
        phase = .recording
        overlay.show(.recording)
        playSound("Tink")
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            self?.finishRecording()
        }
    }

    private func cancelRecording() {
        guard phase == .recording else { return }
        maxDurationTimer?.invalidate()
        _ = recorder.stop()
        phase = .idle
        overlay.hide()
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        maxDurationTimer?.invalidate()
        let samples = recorder.stop()
        let duration = Date().timeIntervalSince(recordingStartedAt)

        guard duration >= minimumDuration, Transcriber.rms(samples) >= silenceRMS else {
            phase = .idle
            overlay.hide()
            return
        }
        playSound("Pop")
        phase = .transcribing
        overlay.show(.transcribing)

        let prompt = settings.prompt
        work.async { [weak self, transcriber] in
            let text = transcriber.transcribe(samples, prompt: prompt)
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                guard !text.isEmpty else {
                    self.overlay.hide()
                    return
                }
                self.lastText = text
                TextInserter.insert(text + " ")
                self.overlay.show(.done)
                self.overlay.hide(after: 0.7)
            }
        }
    }

    private func playSound(_ name: String) {
        guard settings.playSounds, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.4
        sound.play()
    }

    // MARK: - Рядок меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())
        copyLastMenuItem.target = self
        menu.addItem(copyLastMenuItem)
        let settingsItem = NSMenuItem(title: "Налаштування…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Вийти з Holos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        var symbol: String?  // nil — фірмові смужки, як на іконці застосунку
        let text: String
        var tint: NSColor?

        switch (phase, status.model) {
        case (.recording, _):
            text = "Слухаю… Відпустіть \(settings.triggerKey.shortTitle), щоб вставити текст"; tint = .systemRed
        case (.transcribing, _):
            symbol = "ellipsis.circle"; text = "Розпізнаю…"
        case (.idle, .loading):
            symbol = "hourglass"; text = "Завантажую модель…"
        case (.idle, .failed(let message)):
            symbol = "mic.slash"; text = message
        case (.idle, .ready):
            if !status.accessibilityAllowed || !status.microphoneAllowed {
                symbol = "exclamationmark.triangle"; text = "Потрібні дозволи — відкрийте налаштування"
            } else {
                text = "Готово — тримайте \(settings.triggerKey.shortTitle) і говоріть"
            }
        }

        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Holos") } ?? Self.barsIcon
        image.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        stateMenuItem.title = text
        copyLastMenuItem.isHidden = lastText.isEmpty
    }

    /// Іконка для рядка меню: п'ять смужок звукової хвилі, як на іконці застосунку
    private static let barsIcon: NSImage = {
        let heights: [CGFloat] = [6, 11, 15, 9, 5]
        let width: CGFloat = 2, spacing: CGFloat = 1.6
        let size = NSSize(width: 18, height: 18)
        let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * spacing
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for (i, height) in heights.enumerated() {
                let x = (size.width - total) / 2 + CGFloat(i) * (width + spacing)
                let rect = NSRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Holos"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(SettingsView.size)
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        // Щоразу точно по центру екрана, на якому зараз курсор
        // (стандартний center() ставить вікно вище середини)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

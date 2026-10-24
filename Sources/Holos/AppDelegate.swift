import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private let historyMenu = NSMenu()
    private let microphoneMenu = NSMenu()
    private let languageMenu = NSMenu()
    private let triggerKeyMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var maxDurationTimer: Timer?

    private var terminationSignal: DispatchSourceSignal?

    private var phase = Phase.idle { didSet { updateStatusItem() } }
    /// Поточний запис іде без утримання клавіші
    private var handsFree = false
    private var recordingStartedAt = Date()
    /// Останні розпізнані тексти, найновіший першим. Лише в пам'яті — до виходу з Holos.
    private var history: [String] = []
    private let historyLimit = 5
    /// Чому зірвався останній запис; показується в меню до наступної спроби
    private var lastError: String?
    /// Повідомлення в меню до наступного диктування (наприклад, про перезапуск після збою)
    private var notice: String?

    private let minimumDuration = 0.3  // коротше — випадкове натискання
    private let maximumDuration = 180.0 // запобіжник, якщо подія відпускання загубилася
    private let silenceRMS: Float = 0.003
    /// Скільки ще слухати після відпускання клавіші: кінець останнього слова часто звучить уже після нього
    private let recordingTail = 0.15

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Holos \(Self.version, privacy: .public) запущено")
        Watchdog.markRunning()
        handleTerminationSignal()
        if CommandLine.arguments.contains(Watchdog.afterCrashArgument) {
            notice = "Holos перезапустився після збою"
            Log.app.notice("Запущено агентом після збою")
        }
        Watchdog.sync(enabled: settings.restartAfterCrash)
        setupStatusItem()

        hotkey.key = settings.triggerKey
        hotkey.handsFreeEnabled = settings.handsFree
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onFinish = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.onHandsFree = { [weak self] in self?.enterHandsFree() }
        hotkey.start()

        settings.$handsFree.dropFirst().sink { [weak self] enabled in
            self?.hotkey.handsFreeEnabled = enabled
        }.store(in: &cancellables)

        recorder.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.overlay.model.push(rms: rms) }
        }
        recorder.onFailure = { [weak self] message in self?.recordingFailed(message) }

        settings.$triggerKey.dropFirst().sink { [weak self] key in
            self?.hotkey.key = key
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &cancellables)

        settings.$language.dropFirst().sink { [weak self] _ in
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

    func applicationWillTerminate(_ notification: Notification) {
        Watchdog.markStopped()
        // У черзі whisper: якщо якраз іде розпізнавання, дочекаємося його
        work.sync { transcriber.unload() }
        Log.app.notice("Holos завершено")
    }

    /// SIGTERM (pkill, оновлення) — звичайний вихід, а не збій: інакше Watchdog запустив би Holos знову
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let commit = info?["HolosCommit"] as? String else { return short }
        return "\(short) · \(commit)"
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
            Log.app.notice("Універсальний доступ: \(accessibility ? "так" : "ні", privacy: .public)")
        }
        let microphone = Permissions.microphoneAllowed
        if status.microphoneAllowed != microphone {
            status.microphoneAllowed = microphone
            Log.app.notice("Мікрофон: \(microphone ? "так" : "ні", privacy: .public)")
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
            hotkey.reset()
            NSSound.beep()
            return
        }
        lastError = nil
        notice = nil
        handsFree = false
        // Мікрофон відкривається у фоні: клавіша й анімація не чекають на нього
        recorder.start(deviceUID: settings.microphoneUID)
        recordingStartedAt = Date()
        phase = .recording
        overlay.show(.recording)
        playSound("Tink")
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            self?.hotkey.reset()
            self?.finishRecording()
        }
    }

    private func enterHandsFree() {
        guard phase == .recording else { return }
        handsFree = true
        overlay.show(.handsFree)
        updateStatusItem()
    }

    /// Скільки не закривати мікрофон після диктування
    private var keepMicrophoneOpen: TimeInterval {
        settings.keepMicrophoneWarm ? Settings.warmMicrophoneSeconds : 0
    }

    private func cancelRecording() {
        guard phase == .recording else { return }
        maxDurationTimer?.invalidate()
        recorder.stop(keepOpen: keepMicrophoneOpen) { _ in }
        phase = .idle
        overlay.hide()
    }

    /// Мікрофон не відкрився або замовк посеред запису — кажемо про це, а не мовчимо
    private func recordingFailed(_ message: String) {
        guard phase == .recording else { return }
        maxDurationTimer?.invalidate()
        hotkey.reset()
        recorder.stop { _ in }
        showFailure(message)
    }

    private func showFailure(_ message: String) {
        Log.dictation.error("Запис не вдався: \(message, privacy: .public)")
        lastError = message
        phase = .idle
        overlay.show(.failed)
        overlay.hide(after: 1.5)
        NSSound.beep()
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        maxDurationTimer?.invalidate()
        let duration = Date().timeIntervalSince(recordingStartedAt)
        // Поки дописується хвіст і сесія віддає семпли, нового запису не починаємо
        phase = .transcribing
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingTail) { [self] in
            recorder.stop(keepOpen: keepMicrophoneOpen) { [weak self] samples in
                self?.transcribe(samples, duration: duration)
            }
        }
    }

    private func transcribe(_ samples: [Float], duration: TimeInterval) {
        guard duration >= minimumDuration else {
            phase = .idle
            overlay.hide()
            return
        }
        // Справжній мікрофон ніколи не дає рівно нулів — так звучить вимкнений,
        // наприклад вбудований при закритій кришці
        if !samples.isEmpty && !samples.contains(where: { $0 != 0 }) {
            showFailure("Мікрофон передає лише тишу")
            return
        }
        guard Transcriber.rms(samples) >= silenceRMS else {
            phase = .idle
            overlay.hide()
            return
        }
        playSound("Pop")
        overlay.show(.transcribing)

        let prompt = settings.prompt
        let language = settings.language
        let replacements = Replacements(settings.replacements)
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let started = Date()
        work.async { [weak self, transcriber] in
            let text = replacements.apply(to: transcriber.transcribe(samples, prompt: prompt, language: language))
            DispatchQueue.main.async {
                guard let self else { return }
                Log.dictation.info("Розпізнано \(seconds, format: .fixed(precision: 1)) с аудіо за \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) с: \(text.count) символів")
                self.phase = .idle
                guard !text.isEmpty else {
                    self.overlay.hide()
                    return
                }
                self.remember(text)
                TextInserter.insert(text)
                self.overlay.show(.done)
                self.overlay.hide(after: 0.7)
            }
        }
    }

    private func remember(_ text: String) {
        history.insert(text, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
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
        menu.delegate = self
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())
        menu.addItem(submenuItem("Записи", historyMenu))
        menu.addItem(.separator())
        menu.addItem(submenuItem("Мікрофон", microphoneMenu))
        menu.addItem(submenuItem("Мова", languageMenu))
        menu.addItem(submenuItem("Клавіша", triggerKeyMenu))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Налаштування…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        // Видно, яка саме збірка зараз працює
        let versionItem = NSMenuItem(title: "Версія \(Self.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Вийти з Holos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusItem()
    }

    /// Підменю збираються щоразу перед показом: мікрофон могли під'єднати чи від'єднати,
    /// а мову чи клавішу — змінити у вікні налаштувань
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        fillHistoryMenu()
        fillMicrophoneMenu()
        fillLanguageMenu()
        fillTriggerKeyMenu()
    }

    private func fillHistoryMenu() {
        historyMenu.removeAllItems()
        guard !history.isEmpty else {
            let empty = NSMenuItem(title: "Поки що нічого не продиктовано", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
            return
        }
        historyMenu.addItem(.sectionHeader(title: "Клацніть — скопіювати, з ⌥ — вставити"))
        for text in history {
            let preview = Self.preview(text)
            let copy = NSMenuItem(title: preview, action: #selector(copyRecord(_:)), keyEquivalent: "")
            copy.keyEquivalentModifierMask = []
            // З затиснутим ⌥ пункт підміняється на «Вставити» — як після диктування, там, де курсор
            let insert = NSMenuItem(title: "Вставити: \(preview)", action: #selector(insertRecord(_:)), keyEquivalent: "")
            insert.keyEquivalentModifierMask = .option
            insert.isAlternate = true
            for item in [copy, insert] {
                item.target = self
                item.representedObject = text
                item.toolTip = text
                historyMenu.addItem(item)
            }
        }
        historyMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Очистити", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        historyMenu.addItem(clear)
    }

    private func fillMicrophoneMenu() {
        microphoneMenu.removeAllItems()
        let selected = settings.microphoneUID
        let action = #selector(selectMicrophone(_:))
        // Показуємо, який мікрофон реально візьмемо: дротовий раніше за Bluetooth
        let automatic = AudioDevices.resolve(preferredUID: "").map { "Автоматично — \($0.name)" } ?? "Автоматично"
        microphoneMenu.addItem(choice(automatic, "", selected: selected.isEmpty, action: action))
        microphoneMenu.addItem(.separator())
        let devices = AudioDevices.inputs()
        for device in devices {
            microphoneMenu.addItem(choice(device.name, device.uid, selected: device.uid == selected, action: action))
        }
        if !selected.isEmpty && !devices.contains(where: { $0.uid == selected }) {
            let name = settings.microphoneName.isEmpty ? "Вибраний мікрофон" : settings.microphoneName
            let instead = AudioDevices.resolve(preferredUID: selected).map { ", зараз — \($0.name)" } ?? ""
            microphoneMenu.addItem(choice("\(name) (від’єднаний\(instead))", selected, selected: true, action: action))
        }
    }

    private func fillLanguageMenu() {
        languageMenu.removeAllItems()
        let selected = settings.language
        let action = #selector(selectLanguage(_:))
        languageMenu.addItem(choice("Автовизначення", DictationLanguage.auto, selected: selected == DictationLanguage.auto, action: action))
        languageMenu.addItem(.separator())
        var top = DictationLanguage.pinned
        // Вибрану з «Інших мов» теж показуємо тут, щоб одразу було видно, яка зараз
        if let current = DictationLanguage.others.first(where: { $0.code == selected }) { top.append(current) }
        for language in top {
            languageMenu.addItem(choice(language.name, language.code, selected: language.code == selected, action: action))
        }
        languageMenu.addItem(.separator())
        let others = NSMenu()
        for language in DictationLanguage.others {
            others.addItem(choice(language.name, language.code, selected: language.code == selected, action: action))
        }
        languageMenu.addItem(submenuItem("Інші мови", others))
    }

    private func fillTriggerKeyMenu() {
        triggerKeyMenu.removeAllItems()
        for key in TriggerKey.allCases {
            triggerKeyMenu.addItem(choice(key.title, key.rawValue, selected: key == settings.triggerKey, action: #selector(selectTriggerKey(_:))))
        }
        triggerKeyMenu.addItem(.separator())
        let handsFree = NSMenuItem(title: "Двічі натиснути — запис без утримання", action: #selector(toggleHandsFree), keyEquivalent: "")
        handsFree.target = self
        handsFree.state = settings.handsFree ? .on : .off
        triggerKeyMenu.addItem(handsFree)
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func choice(_ title: String, _ value: String, selected: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = selected ? .on : .off
        return item
    }

    /// Початок тексту для меню «Записи»: до `limit` символів, по межі слова, з трикрапкою
    private static func preview(_ text: String, limit: Int = 40) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard line.count > limit else { return line }
        let head = line.prefix(limit)
        // Різати по пробілу, лише якщо від тексту лишається хоча б половина
        let wordEnd = head.lastIndex(of: " ").flatMap { head.distance(from: head.startIndex, to: $0) > limit / 2 ? $0 : nil }
        let cut = wordEnd.map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        var symbol: String?  // nil — фірмові смужки, як на іконці застосунку
        let text: String
        var tint: NSColor?

        switch (phase, status.model) {
        case (.recording, _) where handsFree:
            text = "Слухаю без утримання… \(settings.triggerKey.shortTitle) — вставити, Esc — скасувати"; tint = .systemRed
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
            } else if let lastError {
                symbol = "mic.slash"; text = "Запис не вдався: \(lastError)"
            } else if let notice {
                text = notice
            } else {
                text = "Готово — тримайте \(settings.triggerKey.shortTitle) і говоріть · \(DictationLanguage.name(for: settings.language))"
            }
        }

        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Holos") } ?? Self.barsIcon
        image.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        stateMenuItem.title = text
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

    @objc private func copyRecord(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func insertRecord(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // Даємо меню закритися, щоб фокус повернувся в поле, де стоїть курсор
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { TextInserter.insert(text) }
    }

    @objc private func clearHistory() {
        history.removeAll()
    }

    @objc private func toggleHandsFree() {
        settings.handsFree.toggle()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        settings.microphoneUID = sender.representedObject as? String ?? ""
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.language = code
    }

    @objc private func selectTriggerKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = TriggerKey(rawValue: raw) else { return }
        settings.triggerKey = key
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

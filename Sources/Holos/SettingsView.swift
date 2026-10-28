import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// Вкладки вікна налаштувань (див. SettingsWindowController). Кожна — звичайна згрупована форма,
// як у Системних параметрах: пояснення — у підписах під розділами й під перемикачами.
// Показуємо лише те, що стосується вибраного: дозволи — коли їх бракує, налаштування whisper — коли вибрано whisper.

private let paneWidth: CGFloat = 520

/// Перемикач із поясненням під назвою — як у Системних параметрах
private struct DescribedToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text(description)
        }
        .toggleStyle(.switch)
    }
}

/// Підпис під розділом — дрібний сірий текст ліворуч, як у Системних параметрах
/// (стандартний footer у згрупованій формі на macOS вирівнюється праворуч)
private struct Footnote: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Багаторядкове поле з підказкою, коли порожнє. TextEditor, а не TextField з axis: .vertical —
/// той у згрупованій формі малює текст жирним.
private struct TextArea: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Індикатор рівня мікрофона, як у Системних параметрах → Звук
private struct LevelMeter: View {
    /// 0…1, де 1 — 0 дБ
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geometry.size.width * level))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }

    /// Мовлення зазвичай −30…−15 дБ — зелена зона; ближче до 0 — ризик перевантаження
    private var color: Color {
        level > 0.9 ? .red : level > 0.8 ? .yellow : .green
    }
}

// MARK: - Загальні

struct GeneralPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var status = AppStatus.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            if needsPermissions {
                Section {
                    permissionRow("Мікрофон", allowed: status.microphoneAllowed) {
                        Permissions.requestMicrophone { _ in }
                    }
                    permissionRow("Універсальний доступ", allowed: status.accessibilityAllowed) {
                        Permissions.requestAccessibility()
                        Permissions.openSettings("Privacy_Accessibility")
                    }
                } header: {
                    Text("Потрібні дозволи")
                } footer: {
                    Footnote("Універсальний доступ — щоб чути клавішу в будь-якій програмі й вставляти текст.")
                }
            }

            Section {
                Picker("Клавіша", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                DescribedToggle(title: "Запис без утримання",
                                description: "Двічі натисніть клавішу й говоріть; ще раз — вставити, Esc — скасувати.",
                                isOn: $settings.handsFree)
                Picker("Мова", selection: $settings.language) {
                    Text("Автовизначення").tag(DictationLanguage.auto)
                    Divider()
                    ForEach(DictationLanguage.pinned) { Text($0.name).tag($0.code) }
                    Divider()
                    ForEach(DictationLanguage.others) { Text($0.name).tag($0.code) }
                }
                Toggle("Звук на початку й у кінці запису", isOn: $settings.playSounds)
                    .toggleStyle(.switch)
            } header: {
                Text("Диктування")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.triggerKey == .fn {
                        Footnote("Для fn у Системних параметрах → Клавіатура встановіть «Натискання 🌐» на «Нічого не робити».", warning: true)
                    }
                    if settings.language == DictationLanguage.auto {
                        Footnote("На коротких фразах автовизначення може сплутати українську з російською — краще вибрати мову явно.", warning: true)
                    }
                }
            }

            Section {
                Toggle("Запускати під час входу в систему", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Перезапускати після збою", isOn: $settings.restartAfterCrash)
                    .toggleStyle(.switch)
                    .onChange(of: settings.restartAfterCrash) { _, enabled in Watchdog.sync(enabled: enabled) }
            } header: {
                Text("Запуск")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.restartAfterCrash && !Watchdog.isInstalledCopy {
                        Footnote("Перезапуск працює лише для копії в /Applications.", warning: true)
                    }
                    Footnote("Holos \(AppDelegate.version) · працює офлайн: аудіо лише в пам’яті й нікуди не надсилається.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: needsPermissions ? 560 : 420)
    }

    private var needsPermissions: Bool {
        !status.microphoneAllowed || !status.accessibilityAllowed
    }

    private func permissionRow(_ title: String, allowed: Bool, request: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if allowed {
                Label("Надано", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Надати…", action: request)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Автозапуск: \(error.localizedDescription, privacy: .public)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Мікрофон

struct MicrophonePane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var microphones: [AudioInputDevice] = []
    @State private var automatic: AudioInputDevice?
    @State private var current: AudioInputDevice?
    @StateObject private var tester = MicrophoneTester()

    var body: some View {
        Form {
            Section {
                Picker("Мікрофон", selection: $settings.microphoneUID) {
                    Text(automatic.map { "Автоматично — \($0.name)" } ?? "Автоматично").tag("")
                    Divider()
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    if !settings.microphoneUID.isEmpty && !microphones.contains(where: { $0.uid == settings.microphoneUID }) {
                        Text("\(settings.microphoneName.isEmpty ? "Вибраний мікрофон" : settings.microphoneName) (від’єднаний)")
                            .tag(settings.microphoneUID)
                    }
                }
            } footer: {
                Footnote("«Автоматично» і коли вибраний від’єднано: спершу дротовий мікрофон, Bluetooth — в останню чергу.")
            }

            Section {
                LabeledContent("Підсилення") {
                    HStack(spacing: 10) {
                        // Без step: інакше macOS малює 36 поділок; до цілих дБ округлює прив'язка
                        Slider(value: gain, in: Settings.gainRange)
                            .frame(width: 190)
                        Text(Self.format(decibels: gain.wrappedValue))
                            .monospacedDigit()
                            .frame(width: Self.trailingWidth, alignment: .trailing)
                    }
                    .disabled(current == nil)
                }
                LabeledContent("Рівень") {
                    HStack(spacing: 10) {
                        LevelMeter(level: tester.level)
                            .frame(width: 190)
                        Button(tester.isRunning ? "Зупинити" : "Перевірити", action: toggleTest)
                            .fixedSize()
                            .frame(width: Self.trailingWidth, alignment: .trailing)
                    }
                    .disabled(current == nil)
                }
                if tester.isRunning {
                    Label("Говоріть, як під час диктування…", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                } else if let verdict = tester.verdict {
                    Label(verdict.text, systemImage: verdict.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(verdict.isProblem ? .orange : .green)
                }
            } header: {
                Text("Гучність у Holos")
            } footer: {
                Footnote(gainFootnote)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 340)
        .onAppear(perform: refresh)
        .onDisappear { tester.stop() }
        .onChange(of: settings.microphoneUID) { _, _ in
            tester.stop()
            refresh()
        }
    }

    /// Підсилення для мікрофона, який зараз буде використано
    private var gain: Binding<Double> {
        Binding(
            get: { current.map { settings.gain(for: $0.uid) } ?? 0 },
            set: { raw in
                guard let uid = current?.uid else { return }
                let value = raw.rounded()
                guard value != settings.gain(for: uid) else { return }
                settings.microphoneGains[uid] = value == 0 ? nil : value
                tester.setGain(decibels: value)
            }
        )
    }

    private var gainFootnote: String {
        guard let device = current else { return "Мікрофона немає." }
        var text = "Лише для Holos і «\(device.name)»; системна гучність"
        if let volume = AudioDevices.inputVolume(of: device) {
            text += " (\(Int((volume * 100).rounded())) %)"
        }
        return text + " не змінюється."
    }

    private func toggleTest() {
        if tester.isRunning {
            tester.stop()
        } else {
            tester.start(deviceUID: settings.microphoneUID, gains: settings.microphoneGains)
        }
    }

    /// Однакова ширина праворуч від повзунка й індикатора, щоб вони були одної довжини
    private static let trailingWidth: CGFloat = 96

    static func format(decibels: Double) -> String {
        let value = Int(decibels.rounded())
        return value > 0 ? "+\(value) дБ" : value < 0 ? "−\(-value) дБ" : "0 дБ"
    }

    private func refresh() {
        microphones = AudioDevices.inputs()
        automatic = AudioDevices.resolve(preferredUID: "")
        current = AudioDevices.resolve(preferredUID: settings.microphoneUID)
    }
}

// MARK: - Розпізнавання

struct RecognitionPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var status = AppStatus.shared
    @State private var models: [InstalledModel] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Модель") {
                    HStack {
                        Picker("Модель", selection: modelSelection) {
                            Section("Whisper") {
                                ForEach(models.filter { $0.engine == .whisper }) { Text($0.title).tag($0.path) }
                            }
                            Section("Parakeet — експериментально") {
                                ForEach(models.filter { $0.engine == .parakeet }) { Text($0.title).tag($0.path) }
                            }
                            // Модель з іншого місця, вибрана через «Інша…»
                            if !models.contains(where: { $0.path == settings.activeModelPath }) {
                                Text((settings.activeModelPath as NSString).lastPathComponent).tag(settings.activeModelPath)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Інша…", action: chooseModel)
                            .help("Файл ggml-*.bin (whisper) або тека моделі Parakeet з іншого місця")
                    }
                }
                LabeledContent("Стан") { modelStatus }
            } footer: {
                Footnote(isParakeet
                         ? "Parakeet — експериментальний: у ~10 разів швидший, мову визначає сам, підказок не використовує."
                         : "Ще моделі: scripts/download-model.sh turbo чи parakeet-ultra.")
            }

            // Parakeet підказки не бере, а модель ШІ — бере
            if !isParakeet || settings.correctionEnabled {
                Section {
                    TextArea(text: $settings.prompt, placeholder: "Імена й терміни, які треба писати саме так", height: 54)
                } header: {
                    Text("Підказка")
                } footer: {
                    Footnote(isParakeet
                             ? "Слова в потрібному написанні. Parakeet підказки не використовує — лише модель ШІ."
                             : "Слова в потрібному написанні, з великої літери й крапкою в кінці — модель копіює і стиль.")
                }
            }

            Section {
                DescribedToggle(title: "Прогрівати модель після запуску",
                                description: "Перше диктування після оновлення чи перезавантаження Mac не чекає на підготовку моделі.",
                                isOn: $settings.warmUpModel)
                if !isParakeet {
                    DescribedToggle(title: "Без повторних спроб",
                                    description: "Відповідь завжди швидка, але на поганому звуці текст може бути гіршим.",
                                    isOn: $settings.noFallback)
                }
            } header: {
                Text("Швидкість")
            }

            Section {
                DescribedToggle(title: "Покращувати текст моделлю ШІ",
                                description: "Виправляє слова, які розпізнавання почуло не так, і розділові знаки.",
                                isOn: $settings.correctionEnabled)
                if settings.correctionEnabled {
                    TextField("Сервер і модель", text: $settings.correctionEndpoint,
                              prompt: Text(Settings.defaultCorrectionEndpoint))
                }
            } footer: {
                if settings.correctionEnabled { endpointFootnote }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: height)
        .onAppear { models = InstalledModel.scan() }
    }

    private var isParakeet: Bool { settings.engine == .parakeet }

    private var height: CGFloat {
        switch (isParakeet, settings.correctionEnabled) {
        case (true, false): return 340
        case (true, true): return 575
        case (false, false): return 550
        case (false, true): return 610
        }
    }

    @ViewBuilder
    private var endpointFootnote: some View {
        if let target = TextCorrector.target(settings.correctionEndpoint) {
            if TextCorrector.isLocal(target.url) {
                Footnote("Сервер на цьому Mac (llama serve, Ollama, LM Studio) і назва моделі на ньому.")
            } else {
                Footnote("Лише сервер на цьому Mac — 127.0.0.1 чи localhost.", warning: true)
            }
        } else {
            Footnote("Адреса сервера й назва моделі одним рядком: \(Settings.defaultCorrectionEndpoint)", warning: true)
        }
    }

    /// Вибір моделі сам перемикає рушій: окремого перемикача рушія немає
    private var modelSelection: Binding<String> {
        Binding(
            get: { settings.activeModelPath },
            set: { path in
                guard let model = models.first(where: { $0.path == path }) else { return }
                settings.use(model.path, engine: model.engine)
            }
        )
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch status.model {
        case .loading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Завантажується…") }
        case .ready(let seconds):
            Label(String(format: "Готова (завантажено за %.1f с)", seconds), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Виберіть файл ggml-*.bin (whisper) або теку моделі Parakeet"
        panel.directoryURL = Settings.modelsDirectory
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ParakeetEngine.isModelDirectory(url.path) {
            settings.use(url.path, engine: .parakeet)
        } else if url.pathExtension == "bin" {
            settings.use(url.path, engine: .whisper)
        }
        models = InstalledModel.scan()
    }
}

// MARK: - Заміни

/// Таблиця замін, як «Заміна тексту» в налаштуваннях клавіатури macOS
struct ReplacementsPane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var selection = Set<ReplacementRule.ID>()
    @State private var sample = ""

    var body: some View {
        Form {
            Section {
                Table(settings.replacementRules, selection: $selection) {
                    TableColumn("Модель пише") { rule in
                        TextField("", text: binding(rule.id, \.from), prompt: Text("пі ейч пі шторм"))
                    }
                    TableColumn("Замінити на") { rule in
                        TextField("", text: binding(rule.id, \.to), prompt: Text("прибрати"))
                    }
                }
                .frame(height: 210)
                .overlay {
                    if settings.replacementRules.isEmpty {
                        Text("Замін поки немає — натисніть +")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button(action: add) { Image(systemName: "plus") }
                        .help("Додати заміну")
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .help("Видалити вибрані")
                        .disabled(selection.isEmpty)
                    Spacer()
                }
                .buttonStyle(.borderless)
            } footer: {
                Footnote("Holos замінює ці фрази в уже розпізнаному тексті. Регістр не важить, лише цілі слова; порожнє «Замінити на» прибирає фразу.")
            }

            Section {
                TextField("Перевірити", text: $sample, prompt: Text("відкрий пі ейч пі шторм"))
                if !sample.isEmpty {
                    LabeledContent("Вставиться") {
                        Text(preview).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 410)
    }

    private var preview: String {
        let result = settings.replacements.apply(to: sample)
        return result.isEmpty ? "(нічого — усе прибрано)" : result
    }

    private func add() {
        let rule = ReplacementRule(from: "", to: "")
        settings.replacementRules.append(rule)
        selection = [rule.id]
    }

    private func removeSelected() {
        settings.replacementRules.removeAll { selection.contains($0.id) }
        selection = []
    }

    /// Прив'язка до поля правила за id: Table віддає рядки за значенням
    private func binding(_ id: ReplacementRule.ID, _ field: WritableKeyPath<ReplacementRule, String>) -> Binding<String> {
        Binding(
            get: { settings.replacementRules.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                guard let index = settings.replacementRules.firstIndex(where: { $0.id == id }) else { return }
                settings.replacementRules[index][keyPath: field] = value
            }
        )
    }
}

import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// Вкладки вікна налаштувань (див. SettingsWindowController). Кожна — звичайна згрупована форма,
// як у Системних параметрах: пояснення — у підписах під розділами й під перемикачами.

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
            Section {
                permissionRow("Мікрофон", allowed: status.microphoneAllowed) {
                    Permissions.requestMicrophone { _ in }
                }
                permissionRow("Універсальний доступ", allowed: status.accessibilityAllowed) {
                    Permissions.requestAccessibility()
                    Permissions.openSettings("Privacy_Accessibility")
                }
            } header: {
                Text("Дозволи")
            } footer: {
                Footnote("Універсальний доступ потрібен, щоб чути клавішу в будь-якій програмі та вставляти текст.")
            }

            Section {
                Picker("Клавіша", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                DescribedToggle(title: "Запис без утримання",
                                description: "Двічі коротко натиснути клавішу — і говорити до 3 хв. Ще одне натискання вставляє текст, Esc скасовує.",
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
                    Footnote("Тримайте клавішу, говоріть, відпустіть — текст з’явиться там, де стоїть курсор. Будь-яка інша клавіша під час утримання скасовує запис.")
                    if settings.triggerKey == .fn {
                        Footnote("Для fn у Системних параметрах → Клавіатура встановіть «Натискання 🌐» на «Нічого не робити».", warning: true)
                    }
                    if settings.language == DictationLanguage.auto {
                        Footnote("Автовизначення на коротких фразах може помилитися — наприклад, сприйняти українську як російську. Якщо диктуєте однією мовою, краще вибрати її явно.", warning: true)
                    }
                }
            }

            Section {
                Toggle("Запускати під час входу в систему", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                DescribedToggle(title: "Перезапускати після збою",
                                description: "Якщо Holos аварійно завершиться, він запуститься знову за кілька секунд. Звичайний вихід через меню перезапуску не викликає.",
                                isOn: $settings.restartAfterCrash)
                    .onChange(of: settings.restartAfterCrash) { _, enabled in Watchdog.sync(enabled: enabled) }
            } header: {
                Text("Запуск")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.restartAfterCrash && !Watchdog.isInstalledCopy {
                        Footnote("Перезапуск працює лише для копії в /Applications (scripts/build.sh --install).", warning: true)
                    }
                    Footnote("Holos \(AppDelegate.version). Працює повністю офлайн: аудіо обробляється в пам’яті й нікуди не надсилається та не зберігається.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 660)
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
    @State private var lidClosed = false
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
                Footnote("Вибраний мікрофон береться завжди, коли під’єднаний, — навіть Bluetooth. «Автоматично» і коли вибраний від’єднано: спершу дротовий, Bluetooth — в останню чергу, бо з ним навушники перемикаються в режим гарнітури й звучать гірше.")
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
                Text(current.map { "Гучність «\($0.name)» у Holos" } ?? "Гучність у Holos")
            } footer: {
                Footnote(gainFootnote)
            }

            Section {
                ForEach(microphones) { device in
                    LabeledContent {
                        if device.id == current?.id {
                            Label("Буде використано", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } label: {
                        Text(device.name)
                        Text(description(of: device))
                    }
                }
            } header: {
                Text("Під’єднані мікрофони")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 640)
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
        var text = "Діє лише в Holos і лише для цього мікрофона: звук підсилюється чи приглушується вже після запису, тож системна гучність"
        if let device = current, let volume = AudioDevices.inputVolume(of: device) {
            text += " (зараз \(Int((volume * 100).rounded())) %)"
        }
        text += " та інші програми не змінюються. Натисніть «Перевірити» й кілька секунд говоріть, як під час диктування."
        return text
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
        lidClosed = AudioDevices.isLidClosed
    }

    private func description(of device: AudioInputDevice) -> String {
        let kind: String
        if device.isBuiltIn && lidClosed {
            kind = "Вбудований — кришка закрита, автоматично не береться"
        } else {
            switch device.kind {
            case .wired: kind = device.isBuiltIn ? "Вбудований" : "Дротовий"
            case .wireless: kind = "Бездротовий (Bluetooth, iPhone) — автоматично в останню чергу"
            case .virtual: kind = "Віртуальний — лише якщо вибрати явно"
            }
        }
        let gain = settings.gain(for: device.uid)
        return gain == 0 ? kind : "\(kind) · у Holos \(Self.format(decibels: gain))"
    }
}

// MARK: - Розпізнавання

struct RecognitionPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var status = AppStatus.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Файл") {
                    HStack {
                        Text((settings.modelPath as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.modelPath)
                        Button("Вибрати…", action: chooseModel)
                    }
                }
                LabeledContent("Стан") { modelStatus }
            } header: {
                Text("Модель whisper")
            }

            Section {
                TextArea(text: $settings.prompt, placeholder: "Імена й терміни, які треба писати саме так", height: 54)
            } header: {
                Text("Підказка")
            } footer: {
                Footnote("Слова в потрібному написанні, наприклад «Олексій, Kubernetes, PhpStorm, пулреквест.» Модель сприймає підказку як попередню репліку й копіює з неї написання, регістр і розділові знаки: підказка з малої літери дає речення з малої. Тож пишіть із великої й ставте крапку в кінці, тією мовою, якою диктуєте.")
            }

            Section {
                DisclosureGroup("Що саме отримує модель") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Whisper — модель розпізнавання, а не чат: інструкцій вона не виконує, прихованого системного промпту немає. Єдиний текст, який вона отримує, — ваша підказка.")
                            .foregroundStyle(.secondary)
                        Text(modelInputDescription)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 640)
    }

    /// Збирається з тих самих констант, які використовує Transcriber
    private var modelInputDescription: String {
        let prompt = settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let vad = Transcriber.vadModelPath != nil
            ? "\(Transcriber.vadModelName), запас \(Transcriber.vadPaddingMs) мс"
            : "вимкнено (модель не знайдена)"
        let language = settings.language == DictationLanguage.auto
            ? "auto (визначається за першими 30 с)"
            : "\(settings.language) (\(DictationLanguage.name(for: settings.language).lowercased()), автовизначення вимкнено)"
        let indent = String(repeating: " ", count: 16)
        let filtered = Transcriber.hallucinations.sorted().map { "\(indent)«\($0)»" }.joined(separator: "\n")
        let greedy = settings.fastLongPhrases
            ? "\n\(indent)жадібне для фраз, довших за \(Int(Transcriber.greedyAfterSeconds)) с (експериментально)"
            : ""
        let retries = settings.noFallback
            ? "вимкнено (експериментально)"
            : "до \(Transcriber.fallbackRetries), з вищою «температурою»"
        return """
        аудіо           16 кГц, моно, лише з пам'яті
        language        \(language)
        initial_prompt  \(prompt.isEmpty ? "немає" : "«\(prompt)»")
        декодування     beam search, ширина \(Transcriber.beamSize)\(greedy)
        повтори         \(retries)
        контекст        кожен запис окремо, без попередніх
        VAD             \(vad)
        фільтр          відкидає результат, якщо це лише:
        \(filtered)
                        або згадка Amara.org
        після моделі    заміни: \(settings.replacements.rules.count) правил (вкладка «Заміни»)
        """
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
        panel.title = "Виберіть модель whisper (ggml-*.bin)"
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.directoryURL = Settings.modelsDirectory
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.modelPath = url.path
        }
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
                    Text("Діє правил: \(settings.replacements.rules.count)")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Заміни після розпізнавання")
            } footer: {
                Footnote("Як це працює: модель розпізнає мовлення як уміє, а Holos потім шукає в готовому тексті фрази з лівої колонки й ставить замість них праву. Сама модель про заміни не знає — на відміну від підказки. Регістр не важить, замінюється лише ціле слово чи фраза: «кубер» не зачепить «кубернетис». Порожня права колонка прибирає фразу разом із зайвими комами.")
            }

            Section {
                TextField("Фраза", text: $sample, prompt: Text("відкрий пі ейч пі шторм"))
                LabeledContent("Вставиться") {
                    Text(sample.isEmpty ? "—" : preview)
                        .foregroundStyle(sample.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Перевірка")
            } footer: {
                Footnote("Напишіть фразу так, як її розпізнала модель, — побачите, що з неї зроблять заміни. Розпізнавання тут не запускається.")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 600)
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

// MARK: - Експериментальне

struct ExperimentalPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                DescribedToggle(title: "Прогрівати модель після запуску",
                                description: "Після оновлення Holos чи перезавантаження Mac перше розпізнавання буває повільнішим на 0,2–0,8 с, поки Metal готує шейдери. З прогрівом це стається одразу після запуску (секунда роботи відеоядра), а не на першому диктуванні. В інших випадках різниці немає. Діє з наступного запуску.",
                                isOn: $settings.warmUpModel)
                DescribedToggle(title: "Тримати мікрофон відкритим \(Int(Settings.warmMicrophoneSeconds)) с після диктування",
                                description: "Наступне диктування починається без ~0,2 с на відкриття мікрофона. Поки він відкритий, світиться помаранчевий індикатор; звук не обробляється. З Bluetooth-мікрофоном навушники довше лишаються в режимі гарнітури.",
                                isOn: $settings.keepMicrophoneWarm)
            } header: {
                Label("Безпечно — на якість не впливає", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }

            Section {
                DescribedToggle(title: "Швидше розпізнавати довгі фрази",
                                description: "Для фраз, довших за \(Int(Transcriber.greedyAfterSeconds)) с, — жадібне декодування замість beam search: на 14-секундній фразі на 15–25 % швидше, текст у тесті той самий. На нечіткому мовленні beam search іноді знаходить кращий варіант. Короткі фрази не змінюються.",
                                isOn: $settings.fastLongPhrases)
                DescribedToggle(title: "Без повторних спроб розпізнавання",
                                description: "Коли результат виглядає ненадійним, whisper розпізнає фразу ще до \(Transcriber.fallbackRetries) разів — це може бути зависанням на кілька секунд, а без повторів відповідь завжди швидка. У тестах повтори не знадобилися жодного разу, навіть на зашумленому звуці, тож це радше страховка від рідкісних випадків. Там, де повтор допоміг би, текст буде гіршим.",
                                isOn: $settings.noFallback)
            } header: {
                Label("Може вплинути на якість", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } footer: {
                Footnote("Заміри — на M1 Max із моделлю large-v3 і синтетичним голосом; на живому голосі різниця може бути іншою. Що саме змінюється для моделі, видно на вкладці «Розпізнавання» → «Що саме отримує модель».")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth, height: 570)
    }
}

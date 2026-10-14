import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    static let size = NSSize(width: 540, height: 720)

    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var status = AppStatus.shared
    @State private var microphones: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Клавіша", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Мова", selection: $settings.language) {
                    Text("Автовизначення").tag(DictationLanguage.auto)
                    Divider()
                    ForEach(DictationLanguage.pinned) { Text($0.name).tag($0.code) }
                    Divider()
                    ForEach(DictationLanguage.others) { Text($0.name).tag($0.code) }
                }
                if settings.language == DictationLanguage.auto {
                    Text("Whisper визначає мову за початком запису. На коротких фразах він може помилятися — наприклад, сприйняти українську як російську. Якщо диктуєте однією мовою, краще вибрати її явно.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("Тримайте клавішу, говоріть, відпустіть — текст з’явиться там, де стоїть курсор. Будь-яка інша клавіша під час запису (наприклад, Esc) скасовує його.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.triggerKey == .fn {
                    Text("Для fn у Системних параметрах → Клавіатура встановіть «Натискання 🌐» на «Нічого не робити».")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Диктування")
            }

            Section {
                Picker("Мікрофон", selection: $settings.microphoneUID) {
                    Text("Системний за замовчуванням").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    if !settings.microphoneUID.isEmpty && !microphones.contains(where: { $0.uid == settings.microphoneUID }) {
                        Text("Від’єднаний мікрофон").tag(settings.microphoneUID)
                    }
                }
                Toggle("Звук на початку й у кінці запису", isOn: $settings.playSounds)
            } header: {
                Text("Звук")
            }

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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Підказка для розпізнавання")
                    TextField("", text: $settings.prompt, prompt: Text("Імена й терміни, які треба писати саме так"), axis: .vertical)
                        .lineLimit(2...4)
                        .labelsHidden()
                    Text("Наприклад: «Олексій, Kubernetes, PhpStorm, пулреквест». Пишіть підказку тією мовою, якою диктуєте.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Модель whisper")
            }

            Section {
                Text("Whisper — модель розпізнавання мовлення, а не чат: вона не виконує інструкцій, тому прихованого системного промпту немає. Єдиний текст, який вона отримує, — ваша підказка: модель сприймає її як попередню репліку й підлаштовує під неї написання слів.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(modelInputDescription)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } header: {
                Text("Що саме отримує модель")
            }

            Section {
                permissionRow("Мікрофон", allowed: status.microphoneAllowed) {
                    Permissions.requestMicrophone { _ in }
                }
                permissionRow("Універсальний доступ", allowed: status.accessibilityAllowed) {
                    Permissions.requestAccessibility()
                    Permissions.openSettings("Privacy_Accessibility")
                }
                Text("Універсальний доступ потрібен, щоб чути клавішу в будь-якій програмі та вставляти текст.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Дозволи")
            }

            Section {
                Toggle("Запускати під час входу в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text("Holos працює повністю офлайн: аудіо обробляється локально й нікуди не надсилається.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { microphones = AudioDevices.inputs() }
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
        return """
        аудіо           16 кГц, моно, лише з пам'яті
        language        \(language)
        initial_prompt  \(prompt.isEmpty ? "немає" : "«\(prompt)»")
        декодування     beam search, ширина \(Transcriber.beamSize)
        контекст        кожен запис окремо, без попередніх
        VAD             \(vad)
        фільтр          відкидає результат, якщо це лише:
        \(filtered)
                        або згадка Amara.org
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

    private func permissionRow(_ title: String, allowed: Bool, request: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if allowed {
                Label("Надано", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Надати…", action: request)
            }
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

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Holos: автозапуск: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

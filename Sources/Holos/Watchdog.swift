import Foundation

/// Перезапуск після аварійного завершення.
///
/// Поки Holos працює, він тримає файл-позначку з PID і при нормальному виході її прибирає.
/// Агент launchd (~/Library/LaunchAgents/local.holos.watchdog.plist) раз на 10 с запускає `Holos --watchdog`:
/// якщо позначка є, а процесу вже немає — Holos упав (або його примусово завершили), і його запускаємо знову.
/// Сам застосунок завжди запускається звичайним шляхом, тож двох копій не буває.
///
/// Звичайний LaunchAgent, а не SMAppService: агентам SMAppService macOS ставить обмеження запуску,
/// прив'язане до підпису збірки, і з локальним сертифікатом агент переставав запускатися після
/// кожного перезбирання (AMFI: Launch Constraint Violation).
enum Watchdog {
    static let label = "local.holos.watchdog"
    static let afterCrashArgument = "--after-crash"
    /// Якщо Holos падає раніше, ніж за хвилину після запуску, не перезапускаємо — щоб не зациклитися
    static let minimumUptime: TimeInterval = 60

    private static var markerURL: URL { Settings.supportDirectory.appendingPathComponent("running") }
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var domain: String { "gui/\(getuid())" }

    /// Цей процес запустив агент launchd, а не користувач. Лише за аргументом: змінні середовища
    /// open передає й застосунку, який запускає, — і той вважав би себе агентом.
    static var isWatchdogProcess: Bool {
        CommandLine.arguments.contains("--watchdog")
    }

    /// Агент ставимо лише для встановленої копії: збірка з build/ не повинна підміняти /Applications
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    // MARK: - Застосунок

    static func markRunning() {
        let marker = "\(getpid())\n\(bootTime)\n\(Int(Date().timeIntervalSince1970))\n"
        try? FileManager.default.createDirectory(at: Settings.supportDirectory, withIntermediateDirectories: true)
        try? marker.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    static func markStopped() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Ставить чи прибирає агент відповідно до налаштування
    static func sync(enabled: Bool) {
        guard isInstalledCopy, let executable = Bundle.main.executablePath else { return }
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable, "--watchdog"],
                "StartInterval": 10,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Background",
            ]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
            let changed = (try? Data(contentsOf: plistURL)) != data
            if changed {
                do {
                    try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: plistURL, options: .atomic)
                } catch {
                    Log.app.error("Агент перезапуску: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            if changed || !isLoaded {
                if isLoaded { launchctl("bootout", "\(domain)/\(label)") }
                launchctl("bootstrap", domain, plistURL.path)
                Log.app.notice("Агент перезапуску встановлено")
            }
        } else if FileManager.default.fileExists(atPath: plistURL.path) || isLoaded {
            launchctl("bootout", "\(domain)/\(label)")
            try? FileManager.default.removeItem(at: plistURL)
            Log.app.notice("Агент перезапуску вимкнено")
        }
    }

    static var isLoaded: Bool {
        launchctl("print", "\(domain)/\(label)", quiet: true) == 0
    }

    @discardableResult
    private static func launchctl(_ arguments: String..., quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return -1
        }
        if process.terminationStatus != 0 && !quiet {
            Log.app.error("launchctl \(arguments.joined(separator: " "), privacy: .public): код \(process.terminationStatus)")
        }
        return process.terminationStatus
    }

    // MARK: - Агент

    static func check() -> Int32 {
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8) else { return 0 }
        let fields = marker.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        guard fields.count == 3 else {
            markStopped()
            return 0
        }
        let (pid, boot, launched) = (pid_t(fields[0]), fields[1], fields[2])
        // Позначка лишилася з минулого увімкнення Mac — тоді Holos просто не встиг її прибрати
        guard boot == bootTime else {
            markStopped()
            return 0
        }
        guard !isHolos(pid) else { return 0 }

        markStopped()
        let uptime = Int(Date().timeIntervalSince1970) - launched
        guard Double(uptime) >= minimumUptime else {
            Log.app.error("Holos аварійно завершився через \(uptime) с після запуску — не перезапускаю, щоб не зациклитися")
            return 0
        }
        Log.app.error("Holos аварійно завершився (PID \(pid)) — запускаю знову")

        for attempt in 1...3 {
            // LaunchServices помічає смерть процесу не миттєво, а поки вважає Holos запущеним,
            // open нічого не запускає
            Thread.sleep(forTimeInterval: 1.5)
            // Через open, а не NSWorkspace: з фонового агента без циклу подій NSWorkspace нічого не запускає
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", Bundle.main.bundlePath, "--args", afterCrashArgument]
            // open передає своє середовище застосунку; службове від launchd йому ні до чого
            open.environment = ProcessInfo.processInfo.environment.filter { $0.key != "XPC_SERVICE_NAME" }
            do {
                try open.run()
                open.waitUntilExit()
            } catch {
                Log.app.error("Не вдалося запустити open: \(error.localizedDescription, privacy: .public)")
                return 0
            }
            for _ in 0..<10 {
                if appIsRunning { return 0 }
                Thread.sleep(forTimeInterval: 0.3)
            }
            Log.app.error("Спроба \(attempt): Holos не запустився")
        }
        return 0
    }

    /// Процес живий і це Holos (PID міг дістатися іншій програмі)
    private static func isHolos(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let path = executablePath(of: pid) else { return true }
        return (path as NSString).lastPathComponent == "Holos"
    }

    /// Застосунок уже працює — будь-який інший процес із тим самим виконуваним файлом
    /// (агент launchd двох своїх копій одночасно не запускає)
    private static var appIsRunning: Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).contains { $0 > 0 && $0 != getpid() && executablePath(of: $0) == executable }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    private static var bootTime: Int {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return 0 }
        return time.tv_sec
    }
}

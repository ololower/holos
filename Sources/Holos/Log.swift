import os

/// Журнал Holos у системному журналі macOS. Подивитися:
/// /usr/bin/log show --last 1h --info --predicate 'subsystem == "local.holos"'
/// Розпізнаний текст сюди не пишеться ніколи — лише тривалість, кількість символів, пристрої й помилки.
enum Log {
    static let app = Logger(subsystem: "local.holos", category: "app")
    static let audio = Logger(subsystem: "local.holos", category: "audio")
    static let dictation = Logger(subsystem: "local.holos", category: "dictation")
}

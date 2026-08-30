import AppKit

/// Раскрутка вентиляторов.
///
/// Само приложение сделать это не может: запись в SMC разрешена только root,
/// обычному процессу контроллер её отклоняет. Поэтому вызываем отдельную
/// программу с повышением прав — macOS спросит пароль (и запомнит его
/// на несколько минут, так что подряд спрашивать не будет).
@MainActor
enum Fans {
    static let level = 0.7
    static let seconds = 20

    /// Ищем программу там, где она может лежать.
    static var binaryPath: String? {
        let candidates = [
            NSHomeDirectory() + "/Desktop/lidfan/lidfan",
            "/usr/local/bin/lidfan",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var available: Bool { binaryPath != nil }

    static func spinUp() {
        guard let path = binaryPath else {
            alert("Программа управления вентиляторами не найдена",
                  "Ожидается ~/Desktop/lidfan/lidfan или /usr/local/bin/lidfan.")
            return
        }

        // Путь в одинарных кавычках — на случай пробелов в нём.
        let command = "'\(path)' --set \(level) --seconds \(seconds)"
        let source = "do shell script \"\(command)\" with administrator privileges"

        // Запрос пароля блокирует поток, поэтому уводим в фоновый.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            // Отказ от ввода пароля — не ошибка, молчим о нём.
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            guard code != -128 else { return }
            let message = error[NSAppleScript.errorMessage] as? String ?? "неизвестная ошибка"
            DispatchQueue.main.async {
                alert("Не удалось раскрутить вентиляторы", message)
            }
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

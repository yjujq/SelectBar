import AppKit

/// Готовый к показу пункт панели.
struct Action {
    let title: String
    let symbol: String
    let isRelevant: (String) -> Bool
    let run: (String) -> Void
    var tooltip: String? = nil

    /// Номер смысловой группы: встроенные, ссылки, команды оболочки.
    /// В стеклянном стиле каждая группа получает свою капсулу, как в панелях
    /// инструментов Apple; остальные стили признак не используют.
    var group: Int = 0

    // MARK: - Вспомогательное

    static func urlEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Нажать сочетание с Command. Панель не забирает фокус, поэтому событие
    /// уходит тому приложению, с которым работает пользователь.
    static func pressCommand(key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Расширения, которые чаще встречаются как имена файлов, чем как домены.
    /// Без этого списка «readme.md» и «Selection.swift» уезжали бы в браузер.
    private static let fileExtensions: Set<String> = [
        "md", "txt", "swift", "js", "ts", "py", "rb", "go", "rs", "java", "kt",
        "c", "h", "cpp", "hpp", "m", "mm", "json", "yml", "yaml", "toml", "xml",
        "html", "css", "sh", "zsh", "plist", "png", "jpg", "jpeg", "gif", "svg",
        "pdf", "zip", "tar", "gz", "app", "log", "csv", "sql", "lock", "env",
    ]

    static func looksLikeURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), t.count > 3 else { return false }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return true }
        // Почта — это не ссылка, иначе оба пункта показывались бы разом.
        guard !t.contains("@") else { return false }

        let host = t.split(separator: "/", maxSplits: 1).first.map(String.init) ?? t
        guard let dot = host.lastIndex(of: "."), dot != host.startIndex else { return false }
        let tld = String(host[host.index(after: dot)...]).lowercased()

        // Домен верхнего уровня — только буквы, и не похож на расширение файла.
        guard tld.count >= 2, tld.count <= 24,
              tld.allSatisfy({ $0.isLetter }),
              !fileExtensions.contains(tld) else { return false }
        return true
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        return t[t.index(after: at)...].contains(".")
    }

    /// Выполнить команду оболочки. Текст передаётся переменной окружения,
    /// а подстановка {text} экранируется одинарными кавычками — иначе кавычка
    /// или точка с запятой в выделении сломали бы команду.
    static func runShell(_ command: String, text: String) {
        let quoted = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let filled = command.replacingOccurrences(of: "{text}", with: quoted)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", filled]
        var env = ProcessInfo.processInfo.environment
        env["SB_TEXT"] = text
        task.environment = env
        do { try task.run() } catch {
            NSLog("SelectBar: команда не запустилась: \(error)")
        }
    }

    // MARK: - Перевод

    /// Отдать выделение установленному DeepL.
    ///
    /// У приложения нет ни URL-схемы, ни AppleScript. Служба macOS
    /// «Translate with DeepL» есть, но по умолчанию выключена и объявлена без
    /// типов возврата — текст принимает, результат отдать не может. Поэтому
    /// используем его штатный путь: двойное ⌘C, на которое DeepL показывает
    /// собственное окно с переводом.
    @discardableResult
    static func translateWithDeepLApp(_ text: String) -> Bool {
        guard FileManager.default.fileExists(atPath: "/Applications/DeepL.app") else { return false }
        pressCommand(key: 8)                       // 8 = C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressCommand(key: 8) }
        return true
    }

    /// Запасной путь — веб-переводчик. Направление выбираем сами: кириллицу
    /// переводим на английский, остальное на русский, иначе выходит перевод
    /// «сам в себя».
    static func deepLURL(for text: String) -> String {
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let cyrillic = scalars.filter { $0.value >= 0x0400 && $0.value <= 0x04FF }.count
        let target = (letters > 0 && Double(cyrillic) / Double(letters) > 0.4) ? "en" : "ru"
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        return "https://www.deepl.com/translator#auto/\(target)/\(encoded)"
    }

    // MARK: - Встроенные действия

    static func builtinRun(_ id: String) -> ((String) -> Void)? {
        switch id {
        case "copy":
            return { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "open":
            return { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                open(t.hasPrefix("http") ? t : "https://" + t)
            }
        case "email":
            return { text in
                open("mailto:" + text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "search":
            return { text in open("https://www.google.com/search?q=" + urlEncoded(text)) }
        case "translate":
            return { text in
                if !translateWithDeepLApp(text) { open(deepLURL(for: text)) }
            }
        case "speak":
            return { text in
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                task.arguments = [text]
                try? task.run()
            }
        case "paste":
            return { _ in pressCommand(key: 9) }   // 9 = V
        default:
            return nil
        }
    }
}

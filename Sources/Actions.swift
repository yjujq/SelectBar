import AppKit

/// A bar item ready to be shown.
struct Action {
    let title: String
    let symbol: String
    let run: (String) -> Void
    var tooltip: String? = nil
    /// Whether the bar shows the icon, the title, or both.
    var label: ActionLabel = .icon

    // MARK: - Helpers

    static func urlEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Press a Command combination. The bar never takes focus, so the event
    /// goes to whichever application the user is working in.
    static func pressCommand(key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Extensions seen more often as file names than as domains.
    /// Without this list "readme.md" and "Selection.swift" would open a browser.
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
        // An email address is not a link, or both items would show at once.
        guard !t.contains("@") else { return false }

        let host = t.split(separator: "/", maxSplits: 1).first.map(String.init) ?? t
        guard let dot = host.lastIndex(of: "."), dot != host.startIndex else { return false }
        let tld = String(host[host.index(after: dot)...]).lowercased()

        // A top-level domain is letters only and unlike a file extension.
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

    /// Run a shell command. The text is passed in an environment variable,
    /// and the {text} substitution is wrapped in single quotes — otherwise a
    /// quote or a semicolon in the selection would break the command.
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
            NSLog("SelectBar: the command failed to start: \(error)")
        }
    }

    // MARK: - Translation

    /// Hand the selection to the installed DeepL app.
    ///
    /// The app has neither a URL scheme nor AppleScript support. The macOS
    /// "Translate with DeepL" service exists but is off by default and declares
    /// no return types — it accepts text but cannot hand a result back. So we
    /// use its own supported path: a double ⌘C, on which DeepL shows its own
    /// translation window.
    @discardableResult
    static func translateWithDeepLApp(_ text: String) -> Bool {
        guard FileManager.default.fileExists(atPath: "/Applications/DeepL.app") else { return false }
        pressCommand(key: 8)                       // 8 = C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressCommand(key: 8) }
        return true
    }

    /// The fallback is the web translator. We pick the direction ourselves:
    /// Cyrillic goes to English, everything else to Russian, otherwise the
    /// translation would be into the language it is already in.
    static func deepLURL(for text: String) -> String {
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let cyrillic = scalars.filter { $0.value >= 0x0400 && $0.value <= 0x04FF }.count
        let target = (letters > 0 && Double(cyrillic) / Double(letters) > 0.4) ? "en" : "ru"
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        return "https://www.deepl.com/translator#auto/\(target)/\(encoded)"
    }

    // MARK: - Built-in actions

    /// A key press with no modifiers.
    static func pressPlain(key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        // Stated rather than inherited. The source carries whatever modifiers
        // the session thinks are held, and a press meant to be plain must be
        // plain whatever it thinks.
        down?.flags = []
        up?.flags = []

        down?.post(tap: .cghidEventTap)
        // A beat between the two. Released in the same instant it is pressed,
        // the pair reads as no press at all to some applications — browsers
        // especially, where the key is watched from a script rather than by
        // the text field itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Replace the selection: put it on the pasteboard and paste.
    ///
    /// A small delay lets the bar close first so the paste lands in the
    /// original field rather than in the bar itself.
    static func replaceSelection(with text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { pressCommand(key: 9) }
    }

    /// Collapse runs of whitespace and trim the ends.
    static func squeezeSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Works out a selected sum: + - * / and brackets, and nothing else.
    ///
    /// Written out rather than handed to `NSExpression`, which is the obvious
    /// way and the wrong one twice over. It parses far more than arithmetic —
    /// it will call selectors named in the text it is given, and this text
    /// comes from whatever page the selection was made on — and it raises an
    /// Objective-C exception on anything malformed, which `try?` does not
    /// catch, so a selection ending in a stray "+" would take the app down.
    ///
    /// Returns nothing for anything that is not a sum, and the bar then does
    /// nothing at all, which is the right answer for a selected paragraph.
    static func arithmetic(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // As they are actually written down: typographic operators, and a
        // comma standing in for either separator depending on the company it
        // keeps — a decimal point where there is no point of its own, a
        // thousands separator where there is.
        t = t.replacingOccurrences(of: "\u{00D7}", with: "*")
             .replacingOccurrences(of: "\u{00F7}", with: "/")
             .replacingOccurrences(of: "\u{2212}", with: "-")
        t = t.contains(".")
            ? t.replacingOccurrences(of: ",", with: "")
            : t.replacingOccurrences(of: ",", with: ".")

        var reader = Calculator(t)
        guard let value = reader.parse(), value.isFinite else { return nil }

        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.usesGroupingSeparator = false
        format.maximumFractionDigits = 10
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: NSNumber(value: value))
    }

    /// Recursive descent, so precedence and brackets come out of the shape of
    /// it rather than out of a table.
    private struct Calculator {
        private let chars: [Character]
        private var at = 0
        init(_ text: String) { chars = Array(text) }

        mutating func parse() -> Double? {
            guard let value = sum() else { return nil }
            skipBlanks()
            // Anything left over means this was never a sum in the first
            // place — "2 apples" must not come back as 2.
            return at == chars.count ? value : nil
        }

        private mutating func skipBlanks() {
            while at < chars.count, chars[at].isWhitespace { at += 1 }
        }

        private mutating func sum() -> Double? {
            guard var left = product() else { return nil }
            while true {
                skipBlanks()
                guard at < chars.count, chars[at] == "+" || chars[at] == "-" else { return left }
                let op = chars[at]; at += 1
                guard let right = product() else { return nil }
                left = op == "+" ? left + right : left - right
            }
        }

        private mutating func product() -> Double? {
            guard var left = value() else { return nil }
            while true {
                skipBlanks()
                guard at < chars.count, chars[at] == "*" || chars[at] == "/" else { return left }
                let op = chars[at]; at += 1
                guard let right = value() else { return nil }
                if op == "/" {
                    guard right != 0 else { return nil }
                    left /= right
                } else {
                    left *= right
                }
            }
        }

        private mutating func value() -> Double? {
            skipBlanks()
            guard at < chars.count else { return nil }
            if chars[at] == "-" { at += 1; return value().map { -$0 } }
            if chars[at] == "+" { at += 1; return value() }
            if chars[at] == "(" {
                at += 1
                guard let inner = sum() else { return nil }
                skipBlanks()
                guard at < chars.count, chars[at] == ")" else { return nil }
                at += 1
                return inner
            }
            var digits = ""
            while at < chars.count, chars[at].isNumber || chars[at] == "." {
                digits.append(chars[at]); at += 1
            }
            return digits.isEmpty ? nil : Double(digits)
        }
    }

    /// Hands the selection to one of the system's own services — the same
    /// list that fills the Services submenu of every context menu, and the
    /// reason these need no code of their own beyond a name.
    ///
    /// Onto a pasteboard of ours rather than the general one. A service reads
    /// whatever board it is handed, and handing it the clipboard would mean
    /// every look-up quietly overwrote what the owner had copied.
    ///
    /// The names are the ones the system has registered, checked against its
    /// own list rather than remembered. A name it does not know comes back
    /// false and nothing happens, which is what a missing application looks
    /// like from here.
    static func service(_ name: String, text: String) {
        let board = NSPasteboard(name: NSPasteboard.Name("SelectBarService"))
        board.clearContents()
        board.setString(text, forType: .string)
        if !NSPerformService(name, board) {
            NSLog("SelectBar: the system does not know the service “\(name)”")
        }
    }

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

        // The system's own, by name. Every one of these is a line because
        // macOS already wrote the rest of it.
        case "lookUp":
            return { service("Look Up in Dictionary", text: $0) }
        case "sticky":
            return { service("Make Sticky", text: $0) }
        case "readingList":
            return { service("Add to Reading List", text: $0) }
        case "mailSelection":
            return { service("Mail/New Email With Selection", text: $0) }
        case "textEdit":
            return { service("New TextEdit Window Containing Selection", text: $0) }
        case "showMap":
            return { service("Show Map", text: $0) }
        case "summarize":
            return { service("Summarize", text: $0) }

        case "calc":
            return { text in
                guard let answer = arithmetic(text) else { return }
                replaceSelection(with: answer)
            }

        case "selectAll":
            // The bar never takes focus, so this lands in the field the
            // selection came from. What follows is a larger selection, which
            // brings the bar straight back with everything in it — which is
            // the point: select all, then act on the lot.
            return { _ in pressCommand(key: 0) }   // 0 = A

        case "pasteGo":
            // Paste, then act on what was pasted — an address bar goes to the
            // address, a search field searches, a message field sends.
            return { _ in
                pressCommand(key: 9)               // 9 = V
                // The field needs a moment to take the paste before it is told
                // to act on it. A pasted address is not simply text arriving:
                // an address bar re-reads it, offers completions and lays
                // itself out again, and a Return that lands in the middle of
                // that is dropped. A tenth of a second was not enough —
                // reported as pasting and then doing nothing at all. A third
                // still reads as instant.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    pressPlain(key: 36)            // 36 = Return
                }
            }

        // Text transformations modelled on PopClip's extensions.
        case "upper":
            return { replaceSelection(with: $0.uppercased()) }
        case "lower":
            return { replaceSelection(with: $0.lowercased()) }
        case "title":
            return { replaceSelection(with: $0.localizedCapitalized) }
        case "trim":
            return { replaceSelection(with: squeezeSpaces($0)) }
        case "sortLines":
            return { text in
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                replaceSelection(with: lines.joined(separator: "\n"))
            }
        case "cut":
            return { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                // 51 = Delete. No paste here: the selection must be removed,
                // not replaced by the pasteboard's contents.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { pressPlain(key: 51) }
            }
        case "sentence":
            return { text in
                let lower = text.lowercased()
                guard let first = lower.first else { return }
                replaceSelection(with: String(first).uppercased() + lower.dropFirst())
            }
        case "slugify":
            return { text in
                let allowed = CharacterSet.alphanumerics
                let parts = text.lowercased().unicodeScalars
                    .map { allowed.contains($0) ? Character($0) : " " }
                replaceSelection(with: String(parts)
                    .split(separator: " ")
                    .joined(separator: "-"))
            }
        case "reverseLines":
            return { text in
                let lines = text.components(separatedBy: .newlines).reversed()
                replaceSelection(with: lines.joined(separator: "\n"))
            }
        case "noSpaces":
            return { text in
                replaceSelection(with: text.filter { !$0.isWhitespace })
            }
        case "quote":
            return { replaceSelection(with: "\u{201C}" + $0 + "\u{201D}") }
        case "comment":
            return { text in
                let lines = text.components(separatedBy: .newlines).map { "// " + $0 }
                replaceSelection(with: lines.joined(separator: "\n"))
            }
        case "urlEncode":
            return { replaceSelection(with: urlEncoded($0)) }
        case "base64":
            return { replaceSelection(with: Data($0.utf8).base64EncodedString()) }

        case "joinLines":
            return { text in
                // Newlines to spaces, then collapse: otherwise indentation
                // leaves double spaces behind.
                let joined = text.components(separatedBy: .newlines).joined(separator: " ")
                replaceSelection(with: squeezeSpaces(joined))
            }
        default:
            return nil
        }
    }
}

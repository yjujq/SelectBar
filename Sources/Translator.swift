import AppKit
import NaturalLanguage
import Security
import SwiftUI

/// Translation through the DeepL API, shown in SelectBar's own panel.
///
/// The DeepL app can only be reached by a double ⌘C, and then it is DeepL's
/// window that opens, somewhere of its own choosing. With an API key the text
/// goes to DeepL directly and the result comes back here, to a panel by the
/// pointer — where the bar was, which is where the text is.
enum Translator {
    // MARK: - Key

    /// Kept in the Keychain rather than in the preferences file, which any
    /// process running as the user can read.
    private static let service = "SelectBar.DeepL"

    static var apiKey: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(base as CFDictionary)
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static var hasKey: Bool { !apiKey.isEmpty }

    // MARK: - Languages

    /// A language to translate into. For the API `id` is DeepL's code
    /// ("EN-US"); for the app it is the name its list shows ("English
    /// (American)"), which is all the app lets us pick by.
    struct Language: Hashable, Codable, Identifiable {
        let id: String
        let name: String
    }

    private static var mode: String { hasKey ? "api" : "app" }

    /// The chosen language, per source: a code means nothing to the app and
    /// a name nothing to the API. Nil is Automatic.
    static var chosenTarget: Language? {
        get {
            UserDefaults.standard.data(forKey: "translateTo.\(mode)")
                .flatMap { try? JSONDecoder().decode(Language.self, from: $0) }
        }
        set {
            let data = newValue.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: "translateTo.\(mode)")
        }
    }

    /// Asked for once and remembered: the list hardly ever changes, and
    /// fetching it from the app means opening its menu.
    static var cachedLanguages: [Language] {
        UserDefaults.standard.data(forKey: "languages.\(mode)")
            .flatMap { try? JSONDecoder().decode([Language].self, from: $0) } ?? []
    }

    @MainActor
    static func languages() async throws -> [Language] {
        let cached = cachedLanguages
        if !cached.isEmpty { return cached }
        let list = try await serial { hasKey ? try await apiLanguages() : try await DeepLApp.languages() }
        if !list.isEmpty {
            UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "languages.\(mode)")
        }
        return list
    }

    // MARK: - Request

    /// Cyrillic goes to English, everything else to Russian; otherwise the
    /// translation would be into the language the text is already in.
    static func targetLanguage(for text: String) -> String {
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let cyrillic = scalars.filter { $0.value >= 0x0400 && $0.value <= 0x04FF }.count
        return (letters > 0 && Double(cyrillic) / Double(letters) > 0.4) ? "en" : "ru"
    }

    struct Result {
        let text: String
        var sourceName: String? = nil
        var targetName: String? = nil
        /// DeepL's dictionary for a word or a short phrase; empty otherwise.
        var dictionary: [DictionaryEntry] = []
        /// The translation is in; the dictionary is still being read.
        var dictionaryPending = false
    }

    /// One headword with its part of speech, as DeepL's dictionary lists it.
    struct DictionaryEntry: Identifiable {
        let id = UUID()
        let headword: String
        let partOfSpeech: String
        var senses: [Sense] = []
    }

    struct Sense: Identifiable {
        let id = UUID()
        let text: String
        /// "adj", "f [colloq.]" and the like.
        let tag: String
        /// Listed by DeepL under "less common".
        let rare: Bool
        var examples: [(source: String, target: String)] = []
    }

    enum Failure: LocalizedError {
        case badKey, quota, tooMany, http(Int), empty

        var errorDescription: String? {
            switch self {
            case .badKey:  return "DeepL did not accept the API key."
            case .quota:   return "This month's DeepL character quota is used up."
            case .tooMany: return "Too many requests to DeepL. Try again in a moment."
            case .http(let code): return "DeepL answered with an error (\(code))."
            case .empty:   return "DeepL returned no translation."
            }
        }
    }

    /// Through the API with a key, through the app without one. `early`
    /// gets the translation as soon as it is in, before the dictionary,
    /// which DeepL shows a moment later.
    @MainActor
    static func perform(_ text: String, to language: Language?,
                        early: (@MainActor (Result) -> Void)? = nil) async throws -> Result {
        try await serial {
            hasKey ? try await translate(text, to: language)
                   : try await DeepLApp.translate(text, to: language, early: early)
        }
    }

    /// One conversation with DeepL at a time. The app has a single pair of
    /// text areas and a single language menu: a translation started while
    /// another was waiting, or while the list of languages was being read,
    /// would read the other's answer.
    @MainActor private static var tail: Task<Void, Never>?

    /// Gets the DeepL page ready ahead of the first translation.
    @MainActor
    static func prewarm(start: Bool = false) async {
        _ = try? await serial { await DeepLApp.warm(start: start) }
    }

    @MainActor
    private static func serial<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private static func request(_ path: String) -> URLRequest {
        let key = apiKey
        // Free keys end in ":fx" and live on their own host.
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.timeoutInterval = 15
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw Failure.badKey
        case 456: throw Failure.quota
        case 429: throw Failure.tooMany
        default: throw Failure.http(status)
        }
    }

    static func translate(_ text: String, to language: Language?) async throws -> Result {
        // Plain "EN" is deprecated as a target; DeepL wants a variant.
        let code = language?.id ?? (targetLanguage(for: text) == "en" ? "EN-US" : "RU")

        var request = request("/v2/translate")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": [text], "target_lang": code,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["translations"] as? [[String: Any]])?.first,
              let translated = first["text"] as? String else { throw Failure.empty }
        let source = first["detected_source_language"] as? String ?? ""
        return Result(text: translated,
                      sourceName: languageName(code: source),
                      targetName: language?.name ?? languageName(code: code))
    }

    private static func apiLanguages() async throws -> [Language] {
        let (data, response) = try await URLSession.shared.data(for: request("/v2/languages?type=target"))
        try check(response)
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let code = item["language"] as? String, let name = item["name"] as? String else { return nil }
            return Language(id: code, name: name)
        }
    }

    static func languageName(code: String) -> String? {
        guard !code.isEmpty else { return nil }
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code
        return Locale(identifier: "en").localizedString(forLanguageCode: base)
    }

    // MARK: - Popover

    /// The translation is shown in a real popover, the one macOS itself uses
    /// for Look Up and for Translate: the system material, the arrow, the
    /// animation, light and dark — all of it AppKit's rather than imitated.
    ///
    /// A popover hangs off a view in a window of whoever shows it, so, as with
    /// Look Up, this one hosts it: a window a point across at the pointer.
    @MainActor private static var host: NSPanel?
    @MainActor private static var popover: NSPopover?
    @MainActor private static var monitors: [Any] = []

    @MainActor
    static func show(_ text: String) {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        close()
        SystemTranslation.close()

        let at = NSEvent.mouseLocation
        // The side is chosen here, once, and the content is held to the room
        // on that side. Left to itself the popover turns over whenever it
        // outgrows the room it has: shown above with the short Translation
        // tab, it went below the moment the taller Alternatives tab was
        // opened, and in the top half of the screen that was every time.
        let visible = (NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let arrowAndMargin: CGFloat = 6 + 14 + 10
        let above = visible.maxY - at.y - arrowAndMargin
        let below = at.y - visible.minY - arrowAndMargin
        // Above, as the bar was, unless it leaves too little for even the
        // short tab and below is roomier.
        let up = above >= 320 || above >= below
        let room = up ? above : below
        let window = HostPanel(contentRect: NSRect(x: at.x, y: up ? at.y + 6 : at.y - 6, width: 1, height: 1),
                               styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView = anchor
        // Key without activating, so the translation can be selected and
        // copied with ⌘C while the application in front stays in front.
        window.makeKeyAndOrderFront(nil)
        host = window

        let model = TranslationModel(original: original, room: room)
        let controller = NSHostingController(rootView: TranslationView(model: model))
        // The popover follows the content as the translation arrives.
        controller.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.contentViewController = controller
        // Closed by our own watchers: a transient popover listens for clicks
        // only inside this application, and the clicks that should close it
        // land in another.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: up ? .maxY : .minY)
        self.popover = popover

        watchForDismissal()
        model.run()
    }

    @MainActor
    static func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        popover?.close()
        popover = nil
        host?.orderOut(nil)
        host = nil
    }

    /// A click anywhere outside the popover or Escape puts it away, like the bar.
    @MainActor
    private static func watchForDismissal() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                     handler: { _ in
            MainActor.assumeIsolated { close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return }   // 53 = Escape
            MainActor.assumeIsolated { close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }) { monitors.append(m) }
    }

    private final class HostPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

// MARK: - DeepL app

/// Translation through the installed DeepL app, without an API key and
/// without its window.
///
/// The app offers nothing to script it with, but its main window is a web view
/// open to Accessibility: the source and the translation are two text areas,
/// the target language is a menu button, and the dictionary below is plain
/// text. Writing into the first area makes DeepL translate, and the rest can
/// be read or pressed.
///
/// The window only exists while DeepL is in front: it hides the moment the app
/// loses focus. But its web area, found while the window was up, stays alive
/// after it hides, and everything in the page can still be found through it.
/// So the window is opened once, for a moment, to find the web area; after
/// that every translation — a change of language included, which redraws the
/// text areas — happens with the window out of sight. Should DeepL quit,
/// reload, or be left on another tab, the web area is looked for again the
/// same way.
@MainActor
enum DeepLApp {
    nonisolated static let bundleID = "com.linguee.DeepLCopyTranslator"

    nonisolated static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static var pid: pid_t = 0
    private static var web: AXUIElement?
    /// DeepL's main window, and where the person keeps it.
    private static var window: AXUIElement?
    private static var home: CGPoint?
    private static var parked: CGPoint?

    enum Failure: LocalizedError {
        case notInstalled, noWindow, timeout, asleep, noLanguage(String)
        /// The free plan's characters are used up; DeepL says when they come back.
        case limit(String)

        var isLimit: Bool { if case .limit = self { return true } else { return false } }

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "The DeepL app is not installed."
            case .noWindow:     return "Could not reach the DeepL window. Is DeepL signed in and working?"
            case .timeout, .asleep: return "DeepL did not answer in time."
            case .noLanguage(let name): return "DeepL has no “\(name)” to translate into."
            case .limit(let when): return "DeepL’s free limit is used up. " + when
            }
        }
    }

    // MARK: Translation

    /// The free plan's notice in place of the source: "You've reached your
    /// free usage limit." with "You can use the free translator again in 3
    /// days." after it. While it shows, the source takes no text, and waiting
    /// for a translation would wait for nothing.
    private static func usageLimit(in web: AXUIElement) -> Failure? {
        var texts: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 18, texts.count < 400 else { return }
            if string(e, kAXRoleAttribute) == kAXStaticTextRole, let v = string(e, kAXValueAttribute) { texts.append(v) }
            children(of: e, kAXChildrenAttribute).forEach { walk($0, depth + 1) }
        }
        walk(web, 0)
        guard let index = texts.firstIndex(where: { $0.localizedCaseInsensitiveContains("usage limit") }) else { return nil }
        let when = texts.dropFirst(index + 1).first { $0.localizedCaseInsensitiveContains("again") } ?? ""
        return .limit(when)
    }

    /// After a long while out of sight DeepL's page goes to sleep — the
    /// system naps a hidden app and suspends a hidden web view — and the
    /// first text written into it is not taken up. The page answers
    /// Accessibility as if nothing were wrong, so the only sign is DeepL not
    /// responding; then its window is brought up for a moment, as on the very
    /// first translation, which wakes it, and the text is written again.
    static func translate(_ text: String, to language: Translator.Language?,
                          early: (@MainActor (Translator.Result) -> Void)? = nil) async throws -> Translator.Result {
        do {
            return try await attempt(text, to: language, fresh: false, early: early)
        } catch Failure.notInstalled {
            throw Failure.notInstalled
        } catch let limit as Failure where limit.isLimit {
            throw limit
        } catch {
            NSLog("SelectBar: DeepL did not answer (\(error)); waking it and trying again")
            web = nil
            do {
                return try await attempt(text, to: language, fresh: true, early: early)
            } catch {
                NSLog("SelectBar: DeepL failed again: \(error)")
                throw error
            }
        }
    }

    /// `fresh` writes the text even when it is already there: after a failed
    /// try the source may hold it with the translation of something else.
    private static func attempt(_ text: String, to language: Translator.Language?, fresh: Bool,
                                early: (@MainActor (Translator.Result) -> Void)?) async throws -> Translator.Result {
        let web = try await page(wake: fresh)
        if let limit = usageLimit(in: web) { throw limit }

        // Automatic is the same rule as for the API: Cyrillic into English,
        // everything else into Russian. Left to itself the app would go on
        // translating into whatever was picked last.
        let name = language?.name
            ?? (Translator.targetLanguage(for: text) == "en" ? "English (American)" : "Russian")

        var changed = false
        if currentLanguage(in: web, side: "target") != name {
            // Emptied first: with text in it, DeepL translates the old text
            // into the new language, and that answer can land after ours.
            if let (source, _) = translatorAreas(in: web) { write("", into: source) }
            try await select(name, in: web)
            changed = true
        }
        guard var (source, target) = translatorAreas(in: web) else { throw Failure.noWindow }

        let before = value(of: target)
        if value(of: source) == text {
            // The same text again: DeepL has nothing new to say, and waiting
            // for the translation to change would wait forever.
            if !changed, !fresh, !before.isEmpty {
                return try await finish(text, before, in: web, early: early)
            }
            // A new language for the same text: empty it first, so the
            // translation goes through the empty moment the wait looks for.
            write("", into: source)
            try await Task.sleep(for: .milliseconds(150))
        }

        write(text, into: source)

        // DeepL empties the translation as soon as the source changes and
        // fills it in about half a second later. Only what comes after the
        // empty moment is the answer: before it, the old translation — or,
        // right after the window was found, the text itself — can still be
        // sitting there. It counts once it has held still for a moment.
        var cleared = false, last = "", still = 0
        for tick in 0..<240 {
            try await Task.sleep(for: .milliseconds(50))
            // Awake, DeepL empties the translation within a tenth of a
            // second. Still untouched after a second and a half, it is asleep.
            // A page that has only just loaded can take a few seconds over
            // its first text, and is not asleep for it.
            if !cleared, tick >= (Date().timeIntervalSince(foundAt) < 20 ? 120 : 30) {
                throw usageLimit(in: web) ?? Failure.asleep
            }
            if !alive(target), let found = translatorAreas(in: web) { (source, target) = found }
            let now = value(of: target)
            if now.isEmpty { cleared = true; last = ""; still = 0; continue }
            guard cleared, now != text else { continue }
            if now == last {
                still += 1
                if still >= 4 { return try await finish(text, now, in: web, early: early) }
            } else {
                last = now
                still = 0
            }
        }
        if !last.isEmpty { return try await finish(text, last, in: web, early: early) }
        throw Failure.timeout
    }

    /// The page takes a new value only into the area that has the focus:
    /// written while the language button had it — after a pick from its
    /// list — the text was accepted and then quietly put back.
    private static func write(_ text: String, into area: AXUIElement) {
        AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, text as CFString)
    }

    private static func finish(_ text: String, _ translation: String, in web: AXUIElement,
                               early: (@MainActor (Translator.Result) -> Void)?) async throws -> Translator.Result {
        var result = Translator.Result(text: translation,
                                       sourceName: currentLanguage(in: web, side: "source"),
                                       targetName: currentLanguage(in: web, side: "target"))
        guard text.split(whereSeparator: \.isWhitespace).count <= 4 else { return result }
        if let early {
            var partial = result
            partial.dictionaryPending = true
            early(partial)
        }
        result.dictionary = try await dictionary(in: web, for: text)
        return result
    }

    // MARK: Languages

    /// The names in DeepL's target-language menu, read by opening it.
    static func languages() async throws -> [Translator.Language] {
        do {
            return try await readLanguages()
        } catch Failure.notInstalled {
            throw Failure.notInstalled
        } catch {
            web = nil
            return try await readLanguages()
        }
    }

    private static func readLanguages() async throws -> [Translator.Language] {
        let web = try await page()
        guard let button = languageButton(in: web, side: "target") else { throw Failure.noWindow }
        let list = try await openList(with: button, in: web)
        var seen = Set<String>()
        let names = rows(in: list).compactMap(rowName).filter { seen.insert($0).inserted }
        // The same press closes it again.
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        return names.map { Translator.Language(id: $0, name: $0) }
    }

    private static func select(_ name: String, in web: AXUIElement) async throws {
        for _ in 0..<2 {
            guard let button = languageButton(in: web, side: "target") else { throw Failure.noWindow }
            let list = try await openList(with: button, in: web)
            guard let row = rows(in: list).first(where: { rowName($0) == name }) else {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
                throw Failure.noLanguage(name)
            }
            // The list is long and scrolls; a row out of sight takes no press.
            AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
            try await Task.sleep(for: .milliseconds(80))
            AXUIElementPerformAction(row, kAXPressAction as CFString)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                if currentLanguage(in: web, side: "target") == name { return }
            }
        }
        throw Failure.noLanguage(name)
    }

    /// The menu is a list in the page; the button that opens it also closes
    /// it, so it is pressed only when the list is not already there.
    private static func openList(with button: AXUIElement, in web: AXUIElement) async throws -> AXUIElement {
        if let list = first(in: web, where: { string($0, kAXRoleAttribute) == kAXListRole }) { return list }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            if let list = first(in: web, where: { string($0, kAXRoleAttribute) == kAXListRole }) { return list }
        }
        throw Failure.timeout
    }

    private static func rows(in list: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ e: AXUIElement) {
            if rowName(e) != nil { out.append(e); return }
            children(of: e, kAXChildrenAttribute).forEach(walk)
        }
        walk(list)
        return out
    }

    /// A row reads "German Pin German": the name, then its pin button.
    private static func rowName(_ row: AXUIElement) -> String? {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
            if let label = string(row, attribute), let range = label.range(of: " Pin ") {
                return String(label[..<range.lowerBound])
            }
        }
        return nil
    }

    /// "Select target language. Currently selected: Russian".
    private static func languageButton(in web: AXUIElement, side: String) -> AXUIElement? {
        first(in: web) {
            string($0, kAXRoleAttribute) == kAXPopUpButtonRole
                && label($0).contains("\(side) language")
        }
    }

    private static func currentLanguage(in web: AXUIElement, side: String) -> String? {
        guard let button = languageButton(in: web, side: side),
              let range = label(button).range(of: "Currently selected: ") else { return nil }
        let name = label(button)[range.upperBound...]
            .replacingOccurrences(of: " (detected)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return name.isEmpty ? nil : name
    }

    // MARK: Dictionary

    /// DeepL's dictionary, which it shows for a word or a short phrase.
    ///
    /// It arrives a little after the translation and stays from the text
    /// before until it does, so it is waited for and taken only when its
    /// headwords are the text's own.
    private static func dictionary(in web: AXUIElement, for text: String) async throws -> [Translator.DictionaryEntry] {
        guard text.split(whereSeparator: \.isWhitespace).count <= 4 else { return [] }
        let wanted = normalised(text)
        for _ in 0..<16 {
            if let section = first(in: web, where: { string($0, "AXDOMIdentifier") == "dictionary-section" }) {
                let entries = parseDictionary(section)
                // DeepL files a word under its dictionary form: "sleeps"
                // under "sleep", "walked" under "walk".
                if entries.contains(where: { entry in
                    let head = normalised(entry.headword)
                    return head == wanted
                        || (head.count >= 3 && wanted.hasPrefix(head))
                        || (wanted.count >= 3 && head.hasPrefix(wanted))
                }) { return entries }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return []
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined().trimmingCharacters(in: .whitespaces)
    }

    /// The section is flat: a headword line, then its translations, a "less
    /// common:" marker before the rarer ones, and example pairs as loose text
    /// after the translation they belong to.
    private static func parseDictionary(_ section: AXUIElement) -> [Translator.DictionaryEntry] {
        var entries: [Translator.DictionaryEntry] = []
        var rare = false

        func texts(_ e: AXUIElement) -> [String] {
            var out: [String] = []
            func walk(_ e: AXUIElement) {
                if string(e, kAXRoleAttribute) == kAXStaticTextRole,
                   let v = string(e, kAXValueAttribute)?.trimmingCharacters(in: .whitespaces),
                   !v.isEmpty, v != "·" { out.append(v) }
                children(of: e, kAXChildrenAttribute).forEach(walk)
            }
            walk(e)
            return out
        }

        func walk(_ e: AXUIElement) {
            let role = string(e, kAXRoleAttribute)
            if role == kAXButtonRole || role == "AXHeading" { return }
            let classes = classList(e)
            if classes.contains("lemma_desc") {
                let t = texts(e)
                if let headword = t.first {
                    entries.append(.init(headword: headword, partOfSpeech: t.count > 1 ? t[1] : ""))
                }
                rare = false
                return
            }
            if classes.contains("translation") || classes.contains("translation_desc") {
                if let t = texts(e).first, !entries.isEmpty {
                    let (word, tag) = splitTag(t)
                    entries[entries.count - 1].senses.append(.init(text: word, tag: tag, rare: rare))
                }
                return
            }
            if role == kAXStaticTextRole {
                guard let v = string(e, kAXValueAttribute)?.trimmingCharacters(in: .whitespaces),
                      !v.isEmpty, v != "·" else { return }
                if v.lowercased().hasPrefix("less common") { rare = true; return }
                // An example: the source line, then its translation.
                guard !entries.isEmpty, var sense = entries[entries.count - 1].senses.popLast() else { return }
                if let lastPair = sense.examples.last, lastPair.target.isEmpty {
                    sense.examples[sense.examples.count - 1].target = v
                } else {
                    sense.examples.append((v, ""))
                }
                entries[entries.count - 1].senses.append(sense)
                return
            }
            children(of: e, kAXChildrenAttribute).forEach(walk)
        }
        walk(section)
        return entries.filter { !$0.senses.isEmpty }
    }

    /// "красивый adj" → ("красивый", "adj"); "красотка f [colloq.]" → ("красотка", "f [colloq.]").
    private static func splitTag(_ s: String) -> (String, String) {
        let pattern = #"^(.*?)\s+((?:adj|adv|interj|n|v|m|f|nt|pl|prep|conj|pron|num|art|part|noun|verb|vb)(?:\b.*)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let word = Range(match.range(at: 1), in: s), let tag = Range(match.range(at: 2), in: s)
        else { return (s, "") }
        return (String(s[word]), String(s[tag]))
    }

    // MARK: Finding the page

    /// DeepL's web area, alive and showing the translator.
    /// `wake` brings the window up even when the page can be reached
    /// without it: only that wakes a page that has gone to sleep.
    private static func page(wake: Bool = false) async throws -> AXUIElement {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw Failure.notInstalled
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let web, let running, running.processIdentifier == pid, alive(web),
           translatorAreas(in: web) != nil {
            return web
        }

        // Hidden as an app — as SelectBar leaves it — DeepL keeps its window
        // in Accessibility, page and all, though nothing of it is on the
        // screen. Then nothing needs to be shown.
        if !wake, let running, let found = try await hiddenPage(of: running) { return found }
        if running == nil { return try await launch(url) }

        // Bring DeepL forward just long enough to find its window, then hand
        // the focus straight back to whoever had it. The window is put past
        // the corner of the screen while it is up, so it is never seen: a
        // hidden window can still be moved, and DeepL brings it back up
        // wherever it was left. Known from an earlier time, it is moved
        // before it shows at all; the first time, the moment it appears.
        opening = true
        defer { opening = false }
        let previous = NSWorkspace.shared.frontmostApplication
        if let window, running?.processIdentifier == pid, alive(window) {
            park(window)
        } else {
            NSLog("SelectBar: DeepL's window is not known yet; it will show while it is found")
            window = nil
            home = nil; parked = nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.5)

        // DeepL opens on whichever tab it was left on — Write, Files and
        // History have no translator in them, or text areas of their own —
        // and it may have its settings window up as well. So the page is
        // looked for in the main window only, and if the translator is not
        // in it the Translate tab is pressed.
        var found: AXUIElement?
        var pressed = false
        for attempt in 0..<60 {
            // Asked again when no window comes: opened while it is still in
            // front — right after the focus was handed back from an earlier
            // try — DeepL takes no reopen and keeps its window hidden.
            if attempt > 0, attempt % 12 == 0, mainWindow(of: element) == nil {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            if let window = mainWindow(of: element) {
                // Seen for the first time it is already on the screen —
                // DeepL slides it in before Accessibility lists it — and a
                // move now would only drag it across. It is left to slide out
                // as it always does, and is known from then on.
                self.window = window
                if let area = first(in: window, where: { string($0, kAXRoleAttribute) == "AXWebArea" }),
                   translatorAreas(in: area) != nil {
                    found = area
                    break
                }
                if !pressed || attempt % 15 == 0,
                   let tab = descendant(of: window, identifier: "toolbar-tab-translate-text-button") {
                    AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    pressed = true
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let previous, previous.bundleIdentifier != bundleID {
            previous.activate()
            // DeepL hides its window on losing the focus only some of the
            // time — handed back to an app it was not opened from, it can
            // stay up behind it. So it is hidden outright, which is also
            // at once, where its own hiding slides the window off the side.
            app.hide()
            // Nothing is written into the window until it has hidden, and it
            // goes back to its place only then, out of sight.
            for _ in 0..<20 where mainWindow(of: element) != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if let window, let home { move(window, to: home) }
        guard let found else { throw Failure.noWindow }

        pid = app.processIdentifier
        web = found
        foundAt = Date()
        return found
    }

    /// DeepL not running yet. Started hidden, it still brings itself forward
    /// once its page has loaded — four or five seconds in — and is sent back
    /// the moment it does, with the focus handed to whoever had it. Its page
    /// is then reached in the hidden window as usual.
    private static func launch(_ url: URL) async throws -> AXUIElement {
        opening = true
        defer { opening = false }
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        NSLog("SelectBar: starting DeepL in the background")
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard isDeepL(note) else { return }
            app.hide()
            if let previous, previous.bundleIdentifier != bundleID { previous.activate() }
        }
        defer {
            // It may come forward once more right after; a moment longer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }

        let started = Date()
        while Date().timeIntervalSince(started) < 30 {
            if let found = try await hiddenPage(of: app) { return found }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Failure.noWindow
    }

    private static func hiddenPage(of running: NSRunningApplication) async throws -> AXUIElement? {
        let element = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.5)
        guard let window = mainWindow(of: element) else { return nil }
        var pressed = false
        for _ in 0..<12 {
            if let area = first(in: window, where: { string($0, kAXRoleAttribute) == "AXWebArea" }),
               translatorAreas(in: area) != nil {
                self.window = window
                if running.processIdentifier != pid { home = nil; parked = nil }
                pid = running.processIdentifier
                if web.map({ !CFEqual($0, area) }) ?? true { foundAt = Date() }
                web = area
                return area
            }
            // Left on another tab; the tab button works unseen as well.
            if !pressed, let tab = descendant(of: window, identifier: "toolbar-tab-translate-text-button") {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                pressed = true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: DeepL's own little window

    /// DeepL's Quick Translate window — the small one by the pointer — with
    /// any text, selected anywhere or nowhere.
    ///
    /// It opens on a double ⌘C, reading the pasteboard once the second has
    /// copied. The two are sent to a speck of a window of SelectBar's, made
    /// key for the moment, whose copy puts the text on the pasteboard: the
    /// app in front copies nothing of its own, and what DeepL reads is this.
    static func quickTranslate(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Translator.close()
        SystemTranslation.close()

        let at = NSEvent.mouseLocation
        let panel = KeyCatcher(contentRect: NSRect(x: at.x, y: at.y, width: 1, height: 1),
                               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let catcher = CopyView(text: text)
        panel.contentView = catcher
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(catcher)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            Action.pressCommand(key: 8)                       // 8 = C
            try? await Task.sleep(for: .milliseconds(120))
            Action.pressCommand(key: 8)
            // Long enough for both to arrive and DeepL to read the pasteboard.
            try? await Task.sleep(for: .milliseconds(600))
            panel.orderOut(nil)
            _ = catcher
        }
    }

    private final class KeyCatcher: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Answers ⌘C with the text.
    private final class CopyView: NSView {
        let text: String
        init(text: String) {
            self.text = text
            super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "c" || event.keyCode == 8 else {
                return super.performKeyEquivalent(with: event)
            }
            copy(nil)
            return true
        }

        @objc func copy(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Knowing the window beforehand

    /// Only a window known from before can be moved out of sight before it
    /// shows: a hidden one is not to be found through Accessibility, and a new
    /// one only once it has slid onto the screen. So it is picked up whenever
    /// DeepL comes forward on its own — used by hand, or by its ⌘C ⌘C — and,
    /// if it is still unknown, looked for once when SelectBar or DeepL starts,
    /// rather than on the first translation.
    static func watch() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard isDeepL(note) else { return }
            Task { @MainActor in
                // Listed once it has finished sliding in.
                try? await Task.sleep(for: .milliseconds(800))
                remember()
            }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard isDeepL(note) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                await Translator.prewarm()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await Translator.prewarm()
        }
    }

    /// Finds the page now, while nobody is waiting for a translation.
    /// `start` starts DeepL when it is not running — on a selection, where a
    /// translation may follow; not when SelectBar itself starts.
    static func warm(start: Bool) async {
        guard !Translator.hasKey, installed else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if running == nil, !start { return }
        // A window remembered from a DeepL that has since quit is no window:
        // the one the new DeepL opens is still to be found.
        if let running, let window, running.processIdentifier == pid, alive(window) { return }
        _ = try? await page()
    }

    private nonisolated static func isDeepL(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleID
    }

    private static var opening = false
    /// When the page was last found anew, which may be just as it loaded.
    private static var foundAt = Date.distantPast

    private static func remember() {
        guard !opening,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let found = mainWindow(of: AXUIElementCreateApplication(running.processIdentifier)) else { return }
        if let window, running.processIdentifier == pid, alive(window), CFEqual(window, found) { return }
        if running.processIdentifier != pid { web = nil }
        window = found
        home = nil
        parked = nil
        pid = running.processIdentifier
    }

    // MARK: Out of sight

    /// Further than the system lets a window go: it stops it with a sliver
    /// of a corner left on the screen.
    private static let offscreen = CGPoint(x: 100_000, y: 100_000)

    /// Moves the window past the corner, keeping where it was — unless it is
    /// still parked from a time it could not be put back.
    private static func park(_ window: AXUIElement) {
        if let now = position(of: window), now != parked { home = now }
        move(window, to: offscreen)
        parked = position(of: window)
    }

    private static func position(of window: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func move(_ window: AXUIElement, to point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    // MARK: Accessibility

    private static func alive(_ element: AXUIElement) -> Bool {
        var role: AnyObject?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
    }

    private static func value(of element: AXUIElement) -> String {
        (string(element, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func children(of element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &v)
        return v as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &v)
        return v as? String
    }

    private static func label(_ element: AXUIElement) -> String {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .compactMap { string(element, $0) }.joined(separator: " ")
    }

    private static func classList(_ element: AXUIElement) -> [String] {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &v)
        return v as? [String] ?? []
    }

    /// The translator's window, not the settings or any other DeepL opens.
    private static func mainWindow(of app: AXUIElement) -> AXUIElement? {
        children(of: app, kAXWindowsAttribute).first { string($0, kAXIdentifierAttribute) == "main" }
    }

    private static func descendant(of element: AXUIElement, identifier: String) -> AXUIElement? {
        first(in: element) { string($0, kAXIdentifierAttribute) == identifier }
    }

    private static func first(in element: AXUIElement, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        if test(element) { return element }
        for child in children(of: element, kAXChildrenAttribute) {
            if let hit = first(in: child, where: test) { return hit }
        }
        return nil
    }

    /// The source and the translation, each the first text area that follows
    /// its heading in the page: "Source text" and "Translation results",
    /// recognised by their DOM ids rather than their words, which change with
    /// the interface language.
    private static func translatorAreas(in root: AXUIElement) -> (AXUIElement, AXUIElement)? {
        var heading = ""
        var source: AXUIElement?, target: AXUIElement?
        func walk(_ element: AXUIElement) {
            guard source == nil || target == nil else { return }
            let role = string(element, kAXRoleAttribute)
            if role == "AXHeading", let id = string(element, "AXDOMIdentifier") {
                heading = id
            } else if role == kAXTextAreaRole {
                if heading == "translation-source-heading", source == nil { source = element }
                if heading == "translation-target-heading", target == nil { target = element }
            }
            for child in children(of: element, kAXChildrenAttribute) { walk(child) }
        }
        walk(root)
        guard let source, let target else { return nil }
        return (source, target)
    }
}

// MARK: - View

@MainActor
private final class TranslationModel: ObservableObject {
    enum Tab: Hashable { case translation, alternatives }

    let original: String
    @Published var result: Translator.Result?
    @Published var error: String?
    @Published var tab: Tab = .translation
    @Published var languages: [Translator.Language] = Translator.cachedLanguages
    @Published var target: Translator.Language? = Translator.chosenTarget

    /// The height the popover may take on its side of the pointer.
    let room: CGFloat

    init(original: String, room: CGFloat) {
        self.original = original
        self.room = room
    }

    func run() {
        result = nil
        error = nil
        let text = original, target = target
        Task { @MainActor in
            do {
                result = try await Translator.perform(text, to: target) { self.result = $0 }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            // The list is read once, after the first translation, so reading
            // it never holds one up.
            if languages.isEmpty, let list = try? await Translator.languages() { languages = list }
        }
    }

    func choose(_ language: Translator.Language?) {
        guard language != target else { return }
        target = language
        Translator.chosenTarget = language
        run()
        // Queued after the translation, so the word is looked up in the new
        // language too.
        if let word = lookupWord { lookUp(word, force: true) }
    }

    // MARK: A word from the original

    /// A word or short phrase selected in the original, and DeepL's answer
    /// for it alone: the Alternatives tab shows its dictionary instead of the
    /// whole text's.
    @Published var lookupWord: String?
    @Published var lookupResult: Translator.Result?
    @Published var lookupError: String?

    func lookUp(_ selection: String, force: Bool = false) {
        let word = selection.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !word.isEmpty, word.count <= 60,
              word.split(whereSeparator: \.isWhitespace).count <= 4 else { return }
        tab = .alternatives
        // The whole text is what the tab already shows.
        if word == original.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) {
            clearLookup()
            return
        }
        guard force || word != lookupWord else { return }
        lookupWord = word
        lookupResult = nil
        lookupError = nil
        let target = target
        Task { @MainActor in
            do {
                let result = try await Translator.perform(word, to: target) { partial in
                    if self.lookupWord == word { self.lookupResult = partial }
                }
                // Another word may have been picked meanwhile.
                guard lookupWord == word else { return }
                lookupResult = result
            } catch {
                guard lookupWord == word else { return }
                lookupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func clearLookup() {
        lookupWord = nil
        lookupResult = nil
        lookupError = nil
    }
}

/// Laid out as the system's own Translate popover: the original under its
/// language, a hairline, the translation under its language, a hairline, and
/// the button — with a second tab for DeepL's alternatives.
private struct TranslationView: View {
    @ObservedObject var model: TranslationModel
    @State private var copied: String?

    private let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
                .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)

            switch model.tab {
            case .translation: translationTab
            case .alternatives: alternativesTab
            }

            Divider()
            footer
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Segmented like the system's, but the chosen tab is a grey plate
    /// rather than the accent colour the standard control picks up.
    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("Translation", .translation)
            tabButton(alternativesTitle, .alternatives)
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
    }

    private func tabButton(_ title: String, _ tab: TranslationModel.Tab) -> some View {
        let chosen = model.tab == tab
        return Button {
            model.tab = tab
        } label: {
            Text(title)
                .font(.system(size: 12, weight: chosen ? .medium : .regular))
                .foregroundStyle(chosen ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.gray.opacity(0.32))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var alternativesTitle: String {
        let dictionary = model.lookupWord != nil ? model.lookupResult?.dictionary : model.result?.dictionary
        let count = dictionary?.reduce(0) { $0 + $1.senses.count } ?? 0
        return count > 0 ? "Alternatives (\(count))" : "Alternatives"
    }

    // MARK: Translation

    private var translationTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            section {
                HStack(alignment: .firstTextBaseline) {
                    caption(sourceLanguage ?? " ")
                    Spacer()
                    Text("Select a word for alternatives")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            } content: {
                SelectableText(text: model.original, fontSize: 14, maxLines: 5) { model.lookUp($0) }
            }

            Divider()

            section {
                languageMenu
            } content: {
                if let result = model.result {
                    translation(result.text)
                } else if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Translate with macOS") { SystemTranslation.show(model.original) }
                    }
                } else {
                    progress
                }
            }
        }
    }

    /// Like the language button of the system popover: the name and a
    /// chevron, opening the list.
    private var languageMenu: some View {
        Menu {
            Button {
                model.choose(nil)
            } label: {
                if model.target == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            if !model.languages.isEmpty { Divider() }
            ForEach(model.languages) { language in
                Button {
                    model.choose(language)
                } label: {
                    if model.target == language {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
            }
        } label: {
            Text(targetLanguage)
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Translate into")
    }

    private var progress: some View { progress("Translating…") }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func translation(_ text: String) -> some View {
        let body = Text(text)
            .font(.system(size: 16))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        // A scroll view has no height of its own to offer the popover, so
        // only a translation too tall for the room gets one, and a fixed one.
        // About 35 characters to a line at this width, 22 points a line.
        let limit = max(80, min(300, model.room - 190))
        let estimate = CGFloat(text.count / 35 + 1 + text.filter(\.isNewline).count) * 22
        if estimate > limit {
            ScrollView { body }.frame(height: limit)
        } else {
            body
        }
    }

    // MARK: Alternatives

    @ViewBuilder
    private var alternativesTab: some View {
        if let word = model.lookupWord {
            VStack(alignment: .leading, spacing: 0) {
                lookupHeader(word)
                if let entries = model.lookupResult?.dictionary, !entries.isEmpty {
                    dictionaryList(entries, reserved: 140)
                } else {
                    section {
                        EmptyView()
                    } content: {
                        if let error = model.lookupError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        } else if model.lookupResult == nil {
                            progress
                        } else if model.lookupResult?.dictionaryPending == true {
                            progress("Looking up alternatives…")
                        } else {
                            note("DeepL has no dictionary entries for this word.")
                        }
                    }
                }
            }
        } else if let entries = model.result?.dictionary, !entries.isEmpty {
            dictionaryList(entries, reserved: 100)
        } else {
            section {
                caption(targetLanguage)
            } content: {
                if model.result == nil, model.error == nil {
                    progress
                } else if model.result?.dictionaryPending == true {
                    progress("Looking up alternatives…")
                } else {
                    note(Translator.hasKey
                         ? "Alternatives come from the DeepL app’s dictionary, which the API does not offer."
                         : "DeepL offers alternatives for a single word or a short phrase. Select one in the original to see its alternatives.")
                }
            }
        }
    }

    /// The word picked from the original, its plain translation, and the way
    /// back to the whole text.
    private func lookupHeader(_ word: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(word).font(.system(size: 14, weight: .semibold))
            if let translation = model.lookupResult?.text {
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(translation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.clearLookup()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Back to the whole text")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// `reserved` is what the rest of the popover takes: the tab picker and
    /// the footer, and the word's header when there is one.
    private func dictionaryList(_ entries: [Translator.DictionaryEntry], reserved: CGFloat) -> some View {
        let list = VStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { entry in entryView(entry) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)

        // The list gets what is left on this side of the pointer.
        return ScrollView { list }
            .frame(height: max(80, min(340, estimatedHeight(entries), model.room - reserved)))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func entryView(_ entry: Translator.DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.headword).font(.system(size: 14, weight: .semibold))
                if !entry.partOfSpeech.isEmpty {
                    Text(entry.partOfSpeech).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            ForEach(entry.senses.filter { !$0.rare }) { sense in
                VStack(alignment: .leading, spacing: 2) {
                    senseButton(sense, size: 15)
                    ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(pair.source)
                            if !pair.target.isEmpty { Text(pair.target).foregroundStyle(.tertiary) }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            let rare = entry.senses.filter(\.rare)
            if !rare.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    caption("Less common")
                    FlowLayout(spacing: 4) {
                        ForEach(rare) { sense in senseButton(sense, size: 13) }
                    }
                }
            }
        }
    }

    /// A click copies the word, as the system popover's button copies the
    /// translation.
    private func senseButton(_ sense: Translator.Sense, size: CGFloat) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sense.text, forType: .string)
            copied = sense.text
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(sense.text).font(.system(size: size))
                if !sense.tag.isEmpty {
                    Text(sense.tag).font(.system(size: size - 3)).foregroundStyle(.tertiary)
                }
                if copied == sense.text {
                    Image(systemName: "checkmark").font(.system(size: size - 3)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, sense.rare ? 6 : 0)
            .padding(.vertical, sense.rare ? 2 : 0)
            .background {
                if sense.rare { Capsule().fill(Color.primary.opacity(0.07)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy “\(sense.text)”")
    }

    /// The list's height from its contents, so a short one is not padded out
    /// to the scroll view's full height.
    private func estimatedHeight(_ entries: [Translator.DictionaryEntry]) -> CGFloat {
        var h: CGFloat = 4
        for entry in entries {
            h += 22 + 14
            for sense in entry.senses where !sense.rare {
                h += 25 + CGFloat(sense.examples.count) * 34
            }
            let rare = entry.senses.filter(\.rare).count
            if rare > 0 { h += 20 + CGFloat((rare + 1) / 2) * 26 }
        }
        return h
    }

    // MARK: Pieces

    private var footer: some View {
        HStack {
            Text("DeepL")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
            if DeepLApp.installed {
                Button("Open in DeepL") { DeepLApp.quickTranslate(model.original) }
                    .help("Show this text in DeepL’s own window")
            }
            Button(copied == model.result?.text && copied != nil ? "Copied" : "Copy Translation") {
                guard let text = model.result?.text else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .controlSize(.regular)
            .disabled(model.result == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func section<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Languages

    private var sourceLanguage: String? {
        model.result?.sourceName ?? recognised(model.original)
    }

    private var targetLanguage: String {
        if let name = model.target?.name { return name }
        if let name = model.result?.targetName { return name }
        return model.result.flatMap { recognised($0.text) } ?? "Automatic"
    }

    private func recognised(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.flatMap { Translator.languageName(code: $0.rawValue) }
    }
}

/// Read-only text that can be selected, and says what was selected.
///
/// SwiftUI's own selectable text keeps the selection to itself. This is a
/// text view, so a double-click picks a word as anywhere else on the Mac and
/// a drag picks a phrase; once the mouse is let go, the selection is handed
/// on.
private struct SelectableText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let maxLines: Int
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: NSViewRepresentableContext<SelectableText>) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.typingAttributes = attributes
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: NSViewRepresentableContext<SelectableText>) {
        context.coordinator.onSelect = onSelect
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
    }

    /// Stated on the text itself: a colour set on the view is lost when the
    /// string is replaced, and the text comes out black — invisible on the
    /// dark popover. The full label colour, as the system popover shows its
    /// original; the secondary grey washed out on the popover's material.
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor]
    }

    /// As tall as the text at the width offered, up to `maxLines`; beyond
    /// that it scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: NSViewRepresentableContext<SelectableText>) -> CGSize? {
        let width = proposal.width ?? 332
        guard let view = scroll.documentView as? NSTextView,
              let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        let line = ceil(layout.defaultLineHeight(for: .systemFont(ofSize: fontSize)))
        return CGSize(width: width, height: min(max(used, line), line * CGFloat(maxLines)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String) -> Void
        private var pending: DispatchWorkItem?

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            pending?.cancel()
            let item = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                // Still dragging: the selection is not settled yet.
                if NSEvent.pressedMouseButtons != 0 {
                    self.textViewDidChangeSelection(notification)
                    return
                }
                let range = view.selectedRange()
                guard range.length > 0 else { return }
                self.onSelect((view.string as NSString).substring(with: range))
            }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
    }
}

/// Lays its children out in lines, wrapping as text does.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

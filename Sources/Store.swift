import AppKit
import ServiceManagement

extension Notification.Name {
    static let statusIconVisibilityChanged = Notification.Name("SelectBarStatusIconVisibilityChanged")
}

/// What a bar item does.
enum ActionKind: Codable, Hashable {
    /// A built-in action, identified by its id.
    case builtin(String)
    /// Open a URL. {text} is replaced by the selected text.
    case openURL(String)
    /// Run a shell command. {text} is the selected text, which is also
    /// available in the SB_TEXT environment variable.
    case shell(String)
}

/// When to show an item.
enum ActionContext: String, Codable, CaseIterable, Identifiable {
    case anyText, plainText, links, emails, emptyField, editableText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyText:    return "Any text"
        case .plainText:  return "Plain text (not links or emails)"
        case .links:      return "Links only"
        case .emails:     return "Emails only"
        case .emptyField:   return "Editable fields"
        case .editableText: return "Selected text you can edit"
        }
    }

    func matches(_ text: String) -> Bool {
        switch self {
        case .anyText:    return true
        case .plainText:  return !Action.looksLikeURL(text) && !Action.looksLikeEmail(text)
        case .links:      return Action.looksLikeURL(text)
        case .emails:     return Action.looksLikeEmail(text)
        case .emptyField:   return false    // a separate set, not driven by the text
        case .editableText: return true     // suitability is decided by the editable flag
        }
    }
}

/// What fills the bar's background.
enum BarStyle: String, Codable, CaseIterable, Identifiable {
    case solid, glass, glassClear, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid:      return "Solid"
        case .glass:      return "Glass"
        case .glassClear: return "Glass (clear)"
        case .blur:       return "Blur"
        }
    }
}

/// A light or dark bar, independent of the system.
enum BarAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

struct ActionDefinition: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var symbol: String
    var kind: ActionKind
    var context: ActionContext = .anyText
    var enabled: Bool = true
    /// Hide the item if the selection is longer than this. nil means no limit.
    var maxTextLength: Int? = nil

    var isBuiltin: Bool {
        if case .builtin = kind { return true }
        return false
    }
}

/// Settings and the list of items. Stored in UserDefaults.
@MainActor
final class ActionStore: ObservableObject {
    static let shared = ActionStore()

    @Published var definitions: [ActionDefinition] = [] { didSet { save() } }
    @Published var offerPaste = true { didSet { defaults.set(offerPaste, forKey: "offerPaste") } }

    /// Blink the backlight when a notification arrives.
    @Published var blinkOnNotification = true { didSet { defaults.set(blinkOnNotification, forKey: "blinkOnNotification") } }

    /// Blink the backlight on every press of the space bar.

    /// Whether to show what is playing as a marquee.

    /// Whether to show the menu bar icon. Turning it off hides the only way
    /// into settings, so relaunching the app opens them by itself.
    @Published var showStatusIcon = true {
        didSet {
            defaults.set(showStatusIcon, forKey: "showStatusIcon")
            NotificationCenter.default.post(name: .statusIconVisibilityChanged, object: nil)
        }
    }

    /// The bar's size multiplier; 1.0 means as-is.
    @Published var barScale: Double = 1.0 { didSet { defaults.set(barScale, forKey: "barScale") } }
    @Published var barStyle: BarStyle = .glass { didSet { defaults.set(barStyle.rawValue, forKey: "barStyle") } }
    @Published var barAppearance: BarAppearance = .system { didSet { defaults.set(barAppearance.rawValue, forKey: "barAppearance") } }
    /// The background tint as sRGB components. nil means no tint.
    @Published var barTint: [Double]? = nil { didSet { defaults.set(barTint, forKey: "barTint") } }
    @Published var launchAtLogin = false { didSet { applyLaunchAtLogin() } }

    private let defaults = UserDefaults.standard
    private let key = "actions.v1"
    /// Which URL and command items have already been seeded into the list.
    /// Needed so a deleted item does not come back on every launch.
    private let seededKey = "seededExtras.v1"

    private init() {
        offerPaste = defaults.object(forKey: "offerPaste") as? Bool ?? true
        showStatusIcon = defaults.object(forKey: "showStatusIcon") as? Bool ?? true
        blinkOnNotification = defaults.object(forKey: "blinkOnNotification") as? Bool ?? true
        barScale = defaults.object(forKey: "barScale") as? Double ?? 1.0
        barStyle = (defaults.string(forKey: "barStyle").flatMap(BarStyle.init)) ?? .glass
        barAppearance = (defaults.string(forKey: "barAppearance").flatMap(BarAppearance.init)) ?? .system
        barTint = defaults.array(forKey: "barTint") as? [Double]
        launchAtLogin = SMAppService.mainApp.status == .enabled
        load()
    }

    // MARK: - Built-in items

    static let builtinDefaults: [ActionDefinition] = [
        .init(title: "Copy",      symbol: "doc.on.doc",         kind: .builtin("copy")),
        .init(title: "Open",      symbol: "safari",             kind: .builtin("open"),   context: .links),
        .init(title: "Email",     symbol: "envelope",           kind: .builtin("email"),  context: .emails),
        .init(title: "Search",    symbol: "magnifyingglass",    kind: .builtin("search"),    context: .plainText),
        .init(title: "Translate", symbol: "translate",          kind: .builtin("translate"), context: .plainText),
        .init(title: "Speak",     symbol: "speaker.wave.2",     kind: .builtin("speak"),     context: .plainText,
              maxTextLength: 800),
        .init(title: "Paste",     symbol: "doc.on.clipboard",   kind: .builtin("paste"), context: .emptyField),

        // Below, modelled on PopClip's extensions. All disabled: they are
        // turned on one at a time in the Actions tab so the bar does not grow
        // on its own.

        // Search and sites. They need no code of their own — just URL substitution.
        .init(title: "DuckDuckGo", symbol: "magnifyingglass.circle",
              kind: .openURL("https://duckduckgo.com/?q={text}"), context: .plainText, enabled: false),
        .init(title: "Wikipedia", symbol: "book",
              kind: .openURL("https://en.wikipedia.org/w/index.php?search={text}"), context: .plainText, enabled: false),
        .init(title: "YouTube", symbol: "play.rectangle",
              kind: .openURL("https://www.youtube.com/results?search_query={text}"), context: .plainText, enabled: false),
        .init(title: "Images", symbol: "photo",
              kind: .openURL("https://www.google.com/search?tbm=isch&q={text}"), context: .plainText, enabled: false),
        .init(title: "Maps", symbol: "map",
              kind: .openURL("https://www.google.com/maps/search/{text}"), context: .plainText, enabled: false),
        .init(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
              kind: .openURL("https://github.com/search?q={text}"), context: .plainText, enabled: false),
        .init(title: "Stack Overflow", symbol: "questionmark.bubble",
              kind: .openURL("https://stackoverflow.com/search?q={text}"), context: .plainText, enabled: false),
        .init(title: "ChatGPT", symbol: "bubble.left.and.bubble.right",
              kind: .openURL("https://chatgpt.com/?q={text}"), context: .plainText, enabled: false),
        .init(title: "Claude", symbol: "asterisk",
              kind: .openURL("https://claude.ai/new?q={text}"), context: .plainText, enabled: false),
        .init(title: "Dictionary", symbol: "character.book.closed",
              kind: .openURL("https://www.merriam-webster.com/dictionary/{text}"), context: .plainText, enabled: false),
        .init(title: "IMDb", symbol: "film",
              kind: .openURL("https://www.imdb.com/find/?q={text}"), context: .plainText, enabled: false),
        .init(title: "Spotify", symbol: "music.note",
              kind: .openURL("https://open.spotify.com/search/{text}"), context: .plainText, enabled: false),

        // Text transformations. They replace the selection, so only where
        // typing is allowed.
        .init(title: "UPPERCASE", symbol: "textformat.size.larger",
              kind: .builtin("upper"), context: .editableText, enabled: false),
        .init(title: "lowercase", symbol: "textformat.size.smaller",
              kind: .builtin("lower"), context: .editableText, enabled: false),
        .init(title: "Title Case", symbol: "textformat",
              kind: .builtin("title"), context: .editableText, enabled: false),
        .init(title: "Trim spaces", symbol: "scissors",
              kind: .builtin("trim"), context: .editableText, enabled: false),
        .init(title: "Sort lines", symbol: "arrow.up.arrow.down",
              kind: .builtin("sortLines"), context: .editableText, enabled: false),
        .init(title: "Join lines", symbol: "arrow.left.and.right",
              kind: .builtin("joinLines"), context: .editableText, enabled: false),

        // Second batch.
        .init(title: "Amazon", symbol: "cart",
              kind: .openURL("https://www.amazon.com/s?k={text}"), context: .plainText, enabled: false),
        .init(title: "Reddit", symbol: "bubble.left",
              kind: .openURL("https://www.reddit.com/search/?q={text}"), context: .plainText, enabled: false),
        .init(title: "Scholar", symbol: "graduationcap",
              kind: .openURL("https://scholar.google.com/scholar?q={text}"), context: .plainText, enabled: false),
        .init(title: "LinkedIn", symbol: "person.2",
              kind: .openURL("https://www.linkedin.com/search/results/all/?keywords={text}"), context: .plainText, enabled: false),
        .init(title: "Google Translate", symbol: "character.bubble",
              kind: .openURL("https://translate.google.com/?op=translate&text={text}"), context: .plainText, enabled: false),
        .init(title: "Message", symbol: "message",
              kind: .openURL("sms:&body={text}"), context: .plainText, enabled: false),

        .init(title: "Cut", symbol: "scissors.circle",
              kind: .builtin("cut"), context: .editableText, enabled: false),
        .init(title: "Sentence case", symbol: "text.alignleft",
              kind: .builtin("sentence"), context: .editableText, enabled: false),
        .init(title: "Slugify", symbol: "link",
              kind: .builtin("slugify"), context: .editableText, enabled: false),
        .init(title: "Reverse lines", symbol: "arrow.uturn.up",
              kind: .builtin("reverseLines"), context: .editableText, enabled: false),
        .init(title: "Remove spaces", symbol: "rectangle.compress.vertical",
              kind: .builtin("noSpaces"), context: .editableText, enabled: false),
        .init(title: "Quote", symbol: "quote.opening",
              kind: .builtin("quote"), context: .editableText, enabled: false),
        .init(title: "Comment", symbol: "number",
              kind: .builtin("comment"), context: .editableText, enabled: false),
        .init(title: "URL encode", symbol: "percent",
              kind: .builtin("urlEncode"), context: .editableText, enabled: false),
        .init(title: "Base64", symbol: "shippingbox",
              kind: .builtin("base64"), context: .editableText, enabled: false),

        // --- Dictionaries ---
        // dict:// opens the system Dictionary with no intermediary.
        .init(title: "Apple Dictionary", symbol: "character.book.closed.fill",
              kind: .openURL("dict://{text}"), context: .plainText, enabled: false),
        .init(title: "Thesaurus", symbol: "text.book.closed",
              kind: .openURL("https://www.thesaurus.com/browse/{text}"), context: .plainText, enabled: false),
        .init(title: "Wiktionary", symbol: "character.book.closed",
              kind: .openURL("https://en.wiktionary.org/wiki/{text}"), context: .plainText, enabled: false),
        .init(title: "Urban Dictionary", symbol: "text.bubble",
              kind: .openURL("https://www.urbandictionary.com/define.php?term={text}"), context: .plainText, enabled: false),
        .init(title: "Cambridge", symbol: "books.vertical",
              kind: .openURL("https://dictionary.cambridge.org/dictionary/english/{text}"), context: .plainText, enabled: false),

        // --- Translators ---
        .init(title: "DeepL (web)", symbol: "globe.europe.africa",
              kind: .openURL("https://www.deepl.com/translator#auto/ru/{text}"), context: .plainText, enabled: false),
        .init(title: "Reverso", symbol: "arrow.left.arrow.right",
              kind: .openURL("https://context.reverso.net/translation/english-russian/{text}"), context: .plainText, enabled: false),
        .init(title: "Bing Translator", symbol: "globe",
              kind: .openURL("https://www.bing.com/translator?text={text}"), context: .plainText, enabled: false),

        // --- Notes and tasks ---
        // Notes and Reminders have no URL scheme, hence a command. The text
        // travels in an environment variable, which avoids nested quoting.
        // On first use the system asks permission to control these apps; until
        // it is granted the action does nothing.
        .init(title: "Notes", symbol: "note.text",
              kind: .shell("osascript -e 'on run argv' -e 'tell application \"Notes\" to make new note with properties {body:(item 1 of argv)}' -e 'end run' \"$SB_TEXT\""), context: .anyText, enabled: false),
        .init(title: "Reminder", symbol: "checklist",
              kind: .shell("osascript -e 'on run argv' -e 'tell application \"Reminders\" to make new reminder with properties {name:(item 1 of argv)}' -e 'end run' \"$SB_TEXT\""), context: .anyText, enabled: false),
        .init(title: "Things", symbol: "checkmark.circle",
              kind: .openURL("things:///add?title={text}"), context: .anyText, enabled: false),
        .init(title: "Todoist", symbol: "checkmark.square",
              kind: .openURL("todoist://addtask?content={text}"), context: .anyText, enabled: false),
        .init(title: "Bear", symbol: "square.and.pencil",
              kind: .openURL("bear://x-callback-url/create?text={text}"), context: .anyText, enabled: false),
        .init(title: "Obsidian", symbol: "doc.text",
              kind: .openURL("obsidian://new?content={text}"), context: .anyText, enabled: false),

        // --- Saving links ---
        .init(title: "Raindrop", symbol: "drop",
              kind: .openURL("https://app.raindrop.io/add?link={text}"), context: .links, enabled: false),
        .init(title: "Instapaper", symbol: "bookmark",
              kind: .openURL("https://www.instapaper.com/edit?url={text}"), context: .links, enabled: false),
    ]

    private func load() {
        guard let data = defaults.data(forKey: key),
              var stored = try? JSONDecoder().decode([ActionDefinition].self, from: data) else {
            definitions = Self.builtinDefaults
            return
        }
        // Built-in items added in a newer version are appended at the end,
        // leaving the order and settings of existing ones untouched.
        let known = Set(stored.compactMap { def -> String? in
            if case .builtin(let id) = def.kind { return id }
            return nil
        })
        let knownTitles = Set(stored.map(\.title))
        var seeded = Set(defaults.stringArray(forKey: seededKey) ?? [])
        for def in Self.builtinDefaults {
            switch def.kind {
            case .builtin(let id):
                if !known.contains(id) { stored.append(def) }
            default:
                // URL and command items have no stable identity such as a
                // built-in id, so they are matched by title. This branch used
                // to be missing entirely, and the whole ready-made set — sites,
                // dictionaries, tasks — never reached the list.
                //
                // Two conditions: do not duplicate what is already there, and
                // do not resurrect what the user deleted.
                if !knownTitles.contains(def.title), !seeded.contains(def.title) {
                    stored.append(def)
                    seeded.insert(def.title)
                }
            }
        }
        defaults.set(seeded.sorted(), forKey: seededKey)
        for (index, def) in stored.enumerated() {
            guard case .builtin(let id) = def.kind,
                  let fresh = Self.builtinDefaults.first(where: {
                      if case .builtin(let f) = $0.kind { return f == id }
                      return false
                  }) else { continue }
            if def.context == .anyText && fresh.context != .anyText {
                stored[index].context = fresh.context
            }
            if def.maxTextLength == nil { stored[index].maxTextLength = fresh.maxTextLength }
        }

        // A changed catalogue symbol never reaches an item already stored: the
        // list is persisted whole, so the old glyph is what comes back. This
        // carries one across — but only where the stored glyph is still the
        // one the catalogue used to ship. The symbol field is editable, so an
        // unconditional refresh would quietly overwrite a symbol the user
        // picked. Runs once, then the flag keeps it quiet.
        // Dropping an item from the catalogue does not remove it from a list
        // already stored, so it has to be taken out by hand. Matched on the
        // address rather than the title: a renamed item would slip past a
        // title match. Runs once — otherwise an item the user adds back
        // themselves would be deleted again on the next launch.
        let dropYandexKey = "dropped.yandex.v1"
        if !defaults.bool(forKey: dropYandexKey) {
            stored.removeAll { def in
                if case .openURL(let template) = def.kind {
                    return template.lowercased().contains("yandex")
                }
                return false
            }
            defaults.set(true, forKey: dropYandexKey)
        }

        let claudeSymbolKey = "symbolRefresh.claude.v1"
        if !defaults.bool(forKey: claudeSymbolKey) {
            if let index = stored.firstIndex(where: {
                $0.title == "Claude" && $0.symbol == "sparkles"
            }) {
                stored[index].symbol = "asterisk"
            }
            defaults.set(true, forKey: claudeSymbolKey)
        }

        definitions = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(definitions) else { return }
        defaults.set(data, forKey: key)
    }

    func resetToDefaults() {
        definitions = Self.builtinDefaults
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("SelectBar: could not change the login item: \(error)")
        }
    }

    /// The background tint as an NSColor, if one is set.
    var tintColor: NSColor? {
        guard let c = barTint, c.count == 4 else { return nil }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
    }

    // MARK: - Turning settings into bar actions

    func actions(forSelectedText text: String, editable: Bool) -> [Action] {
        let clip = clipboardPreview()
        return definitions
            .filter { def in
                guard def.enabled else { return false }
                // Paste fits anywhere typing is allowed: in an empty field it
                // simply pastes, over a selection it replaces it.
                if def.context == .emptyField { return editable && clip != nil }
                // Transformations replace the selection by pasting — without
                // the right to type they would simply do nothing.
                if def.context == .editableText { return editable && !text.isEmpty }
                guard def.context.matches(text) else { return false }
                if let limit = def.maxTextLength, text.count > limit { return false }
                return true
            }
            .compactMap { def in
                runtime(def, tooltipSuffix: def.context == .emptyField ? clip : nil)
            }
    }

    /// The start of the pasteboard contents, for the paste button's tooltip.
    private func clipboardPreview() -> String? {
        guard let clip = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    func actionsForEmptyField() -> [Action] {
        guard let short = clipboardPreview() else { return [] }
        return definitions
            .filter { $0.enabled && $0.context == .emptyField }
            .compactMap { runtime($0, tooltipSuffix: short) }
    }

    private func runtime(_ def: ActionDefinition, tooltipSuffix: String? = nil) -> Action? {
        let tooltip = tooltipSuffix.map { "\(def.title): \($0)" } ?? def.title
        switch def.kind {
        case .builtin(let id):
            guard let run = Action.builtinRun(id) else { return nil }
            return Action(title: def.title, symbol: def.symbol,
                          isRelevant: { _ in true }, run: run, tooltip: tooltip)
        case .openURL(let template):
            return Action(title: def.title, symbol: def.symbol, isRelevant: { _ in true },
                          run: { text in
                              let url = template.replacingOccurrences(
                                  of: "{text}", with: Action.urlEncoded(text))
                              Action.open(url)
                          }, tooltip: tooltip)
        case .shell(let command):
            return Action(title: def.title, symbol: def.symbol, isRelevant: { _ in true },
                          run: { text in Action.runShell(command, text: text) },
                          tooltip: tooltip)
        }
    }
}

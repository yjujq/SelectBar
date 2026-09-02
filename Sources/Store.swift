import AppKit
import ServiceManagement

extension Notification.Name {
    static let statusIconVisibilityChanged = Notification.Name("SelectBarStatusIconVisibilityChanged")
}

/// Что делает пункт панели.
enum ActionKind: Codable, Hashable {
    /// Встроенное действие, опознаётся по идентификатору.
    case builtin(String)
    /// Открыть ссылку. {text} заменяется выделенным текстом.
    case openURL(String)
    /// Выполнить команду оболочки. {text} — выделенный текст,
    /// он же доступен в переменной окружения SB_TEXT.
    case shell(String)
}

/// Когда пункт показывать.
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
        case .emptyField:   return false    // отдельный набор, не по тексту
        case .editableText: return true     // пригодность решает признак editable
        }
    }
}

/// Чем залита подложка панели.
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

/// Светлая или тёмная панель независимо от системы.
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
    /// Не показывать пункт, если выделение длиннее этого. nil — без предела.
    var maxTextLength: Int? = nil

    var isBuiltin: Bool {
        if case .builtin = kind { return true }
        return false
    }
}

/// Настройки и список пунктов. Хранится в UserDefaults.
@MainActor
final class ActionStore: ObservableObject {
    static let shared = ActionStore()

    @Published var definitions: [ActionDefinition] = [] { didSet { save() } }
    @Published var offerPaste = true { didSet { defaults.set(offerPaste, forKey: "offerPaste") } }

    /// Мигать подсветкой на приход уведомления.
    @Published var blinkOnNotification = true { didSet { defaults.set(blinkOnNotification, forKey: "blinkOnNotification") } }

    /// Мигать подсветкой на каждое нажатие пробела.

    /// Показывать ли бегущей строкой то, что играет.

    /// Показывать ли значок в строке меню. Выключение прячет единственный вход
    /// в настройки, поэтому повторный запуск приложения открывает их сам.
    @Published var showStatusIcon = true {
        didSet {
            defaults.set(showStatusIcon, forKey: "showStatusIcon")
            NotificationCenter.default.post(name: .statusIconVisibilityChanged, object: nil)
        }
    }

    /// Множитель размеров панели: 1.0 — как сейчас.
    @Published var barScale: Double = 1.0 { didSet { defaults.set(barScale, forKey: "barScale") } }
    @Published var barStyle: BarStyle = .glass { didSet { defaults.set(barStyle.rawValue, forKey: "barStyle") } }
    @Published var barAppearance: BarAppearance = .system { didSet { defaults.set(barAppearance.rawValue, forKey: "barAppearance") } }
    /// Оттенок подложки в виде sRGB-компонент. nil — без оттенка.
    @Published var barTint: [Double]? = nil { didSet { defaults.set(barTint, forKey: "barTint") } }
    @Published var launchAtLogin = false { didSet { applyLaunchAtLogin() } }

    private let defaults = UserDefaults.standard
    private let key = "actions.v1"
    /// Какие пункты со ссылкой и командой уже подсаживались в список.
    /// Нужен, чтобы удалённый пункт не возвращался при каждом запуске.
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

    // MARK: - Встроенные пункты

    static let builtinDefaults: [ActionDefinition] = [
        .init(title: "Copy",      symbol: "doc.on.doc",         kind: .builtin("copy")),
        .init(title: "Open",      symbol: "safari",             kind: .builtin("open"),   context: .links),
        .init(title: "Email",     symbol: "envelope",           kind: .builtin("email"),  context: .emails),
        .init(title: "Search",    symbol: "magnifyingglass",    kind: .builtin("search"),    context: .plainText),
        .init(title: "Translate", symbol: "translate",          kind: .builtin("translate"), context: .plainText),
        .init(title: "Speak",     symbol: "speaker.wave.2",     kind: .builtin("speak"),     context: .plainText,
              maxTextLength: 800),
        .init(title: "Paste",     symbol: "doc.on.clipboard",   kind: .builtin("paste"), context: .emptyField),

        // Ниже — по образцу расширений PopClip. Все выключены: включаются
        // поштучно во вкладке Actions, чтобы панель не разрасталась сама.

        // Поиск и сайты. Своего кода не требуют — это подстановка в адрес.
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
        .init(title: "Claude", symbol: "sparkles",
              kind: .openURL("https://claude.ai/new?q={text}"), context: .plainText, enabled: false),
        .init(title: "Dictionary", symbol: "character.book.closed",
              kind: .openURL("https://www.merriam-webster.com/dictionary/{text}"), context: .plainText, enabled: false),
        .init(title: "IMDb", symbol: "film",
              kind: .openURL("https://www.imdb.com/find/?q={text}"), context: .plainText, enabled: false),
        .init(title: "Spotify", symbol: "music.note",
              kind: .openURL("https://open.spotify.com/search/{text}"), context: .plainText, enabled: false),

        // Преобразования текста. Заменяют выделенное, поэтому только там,
        // где есть право ввода.
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

        // Вторая порция.
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

        // --- Словари ---
        // dict:// открывает системный Словарь без всяких посредников.
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

        // --- Переводчики ---
        .init(title: "DeepL (web)", symbol: "globe.europe.africa",
              kind: .openURL("https://www.deepl.com/translator#auto/ru/{text}"), context: .plainText, enabled: false),
        .init(title: "Yandex Translate", symbol: "character.bubble.fill",
              kind: .openURL("https://translate.yandex.ru/?text={text}"), context: .plainText, enabled: false),
        .init(title: "Reverso", symbol: "arrow.left.arrow.right",
              kind: .openURL("https://context.reverso.net/translation/english-russian/{text}"), context: .plainText, enabled: false),
        .init(title: "Bing Translator", symbol: "globe",
              kind: .openURL("https://www.bing.com/translator?text={text}"), context: .plainText, enabled: false),

        // --- Заметки и задачи ---
        // У Заметок и Напоминаний нет схемы адреса, поэтому команда.
        // Текст идёт переменной окружения — так не нужны вложенные кавычки.
        // При первом запуске система спросит разрешение на управление
        // этими приложениями; до согласия действие ничего не сделает.
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

        // --- Сохранение ссылок ---
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
        // Встроенные пункты, добавленные в новой версии, дописываем в конец,
        // не трогая порядок и настройки уже существующих.
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
                // У пунктов со ссылкой и командой нет устойчивого признака
                // вроде идентификатора встроенного, поэтому опознаём по
                // названию. Раньше эта ветка отсутствовала вовсе, и весь
                // готовый набор — сайты, словари, задачи — в список не попадал.
                //
                // Два условия: не дублировать уже имеющееся и не возвращать
                // то, что пользователь удалил.
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
            NSLog("SelectBar: не удалось изменить автозапуск: \(error)")
        }
    }

    /// Оттенок подложки как NSColor, если задан.
    var tintColor: NSColor? {
        guard let c = barTint, c.count == 4 else { return nil }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
    }

    // MARK: - Превращение настроек в действия панели

    func actions(forSelectedText text: String, editable: Bool) -> [Action] {
        let clip = clipboardPreview()
        return definitions
            .filter { def in
                guard def.enabled else { return false }
                // Вставка уместна везде, где можно вводить: в пустом поле она
                // просто вставит, поверх выделения — заменит его.
                if def.context == .emptyField { return editable && clip != nil }
                // Преобразования заменяют выделенное вставкой — без права
                // ввода они бы просто ничего не сделали.
                if def.context == .editableText { return editable && !text.isEmpty }
                guard def.context.matches(text) else { return false }
                if let limit = def.maxTextLength, text.count > limit { return false }
                return true
            }
            .compactMap { def in
                runtime(def, tooltipSuffix: def.context == .emptyField ? clip : nil)
            }
    }

    /// Начало содержимого буфера — для подсказки на кнопке вставки.
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
                          isRelevant: { _ in true }, run: run, tooltip: tooltip,
                          group: 0)
        case .openURL(let template):
            return Action(title: def.title, symbol: def.symbol, isRelevant: { _ in true },
                          run: { text in
                              let url = template.replacingOccurrences(
                                  of: "{text}", with: Action.urlEncoded(text))
                              Action.open(url)
                          }, tooltip: tooltip, group: 1)
        case .shell(let command):
            return Action(title: def.title, symbol: def.symbol, isRelevant: { _ in true },
                          run: { text in Action.runShell(command, text: text) },
                          tooltip: tooltip, group: 2)
        }
    }
}

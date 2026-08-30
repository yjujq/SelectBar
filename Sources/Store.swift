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
    case anyText, plainText, links, emails, emptyField

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyText:    return "Any text"
        case .plainText:  return "Plain text (not links or emails)"
        case .links:      return "Links only"
        case .emails:     return "Emails only"
        case .emptyField: return "Empty input field"
        }
    }

    func matches(_ text: String) -> Bool {
        switch self {
        case .anyText:    return true
        case .plainText:  return !Action.looksLikeURL(text) && !Action.looksLikeEmail(text)
        case .links:      return Action.looksLikeURL(text)
        case .emails:     return Action.looksLikeEmail(text)
        case .emptyField: return false      // отдельный набор, не по тексту
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
    @Published var blinkOnSpace = false { didSet { defaults.set(blinkOnSpace, forKey: "blinkOnSpace") } }

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

    private init() {
        offerPaste = defaults.object(forKey: "offerPaste") as? Bool ?? true
        showStatusIcon = defaults.object(forKey: "showStatusIcon") as? Bool ?? true
        blinkOnSpace = defaults.object(forKey: "blinkOnSpace") as? Bool ?? false
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
        for builtin in Self.builtinDefaults {
            if case .builtin(let id) = builtin.kind, !known.contains(id) {
                stored.append(builtin)
            }
        }
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

    func actions(forSelectedText text: String) -> [Action] {
        definitions
            .filter { def in
                guard def.enabled, def.context != .emptyField, def.context.matches(text) else { return false }
                if let limit = def.maxTextLength, text.count > limit { return false }
                return true
            }
            .compactMap { runtime($0) }
    }

    func actionsForEmptyField() -> [Action] {
        guard let clip = NSPasteboard.general.string(forType: .string),
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let preview = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let short = preview.count > 40 ? String(preview.prefix(40)) + "…" : preview

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

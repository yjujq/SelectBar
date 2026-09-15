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
/// What a bar button shows: the icon, the title, or both.
enum ActionLabel: String, Codable, CaseIterable, Identifiable {
    case icon, iconAndText, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon:        return "Icon only"
        case .iconAndText: return "Icon and label"
        case .text:        return "Label only"
        }
    }

    var showsIcon: Bool { self != .text }
    var showsText: Bool { self != .icon }
}

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
extension ActionStore {
    /// How the app's own windows are offered to screen captures.
    ///
    /// `.none` means the window server never hands those pixels to anybody —
    /// not a screenshot, not a recording, not a call being shared. That is
    /// needed exactly when the lens is filming, and for one reason: the lens
    /// films what is behind the bar continuously, so a bar that could be
    /// captured would film itself, frame after frame, refracting its own
    /// picture without end. The filter that leaves this application out is
    /// built from the list of applications with windows on screen, and the
    /// first time round the bar may not be in that list yet — so the
    /// exclusion came out empty and the loop closed. This does not depend on
    /// the list at all.
    ///
    /// No other style films anything, and there the bar has no business being
    /// invisible: a bar nobody can screenshot cannot be shown to anyone.
    var windowSharing: NSWindow.SharingType {
        barStyle == .lens ? .none : .readOnly
    }
}

enum BarStyle: String, Codable, CaseIterable, Identifiable {
    case solid, glass, glassClear, blur, lens
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid:      return "Solid"
        case .glass:      return "Glass"
        case .glassClear: return "Glass (clear)"
        case .blur:       return "Blur"
        case .lens:       return "Lens"
        }
    }

    /// Whether the style is one the system draws for us. The lens is not: it
    /// photographs the screen and bends the picture in a shader of our own,
    /// which is why it alone needs a permission — see LensView.
    var needsScreenRecording: Bool { self == .lens }
}

/// How hard the glass bends what lies behind it.
///
/// macOS computes the refraction in the window server, and the recipe is a
/// private CAFilter named `glassBackground` sitting on a CABackdropLayer inside
/// every NSGlassEffectView. Nothing about it is exposed through AppKit — but
/// the filter is parameterised, and its inputs can be read and rewritten:
///
///     inputInnerRefractionAmount   inputInnerRefractionHeight
///     inputOuterRefractionAmount   inputOuterRefractionHeight
///     inputRefractionDistance0/1   inputBlurRadius   inputFaceOpacity
///
/// A stock clear bar comes with amount −60 and height 20. Every case here is
/// that dictionary with different numbers, applied once the glass has drawn
/// itself for the first time — see GlassTuning.
///
/// This is private, so it is written to fail quietly: nothing found, nothing
/// changed, and the bar keeps the system's own look.
enum BarLens: String, Codable, CaseIterable, Identifiable {
    case system, deep, sharp, dome, frost, flat
    case convex, concave, fisheye, cylinder, prism
    case reduce, magnify, bevel, ripple, anamorphic
    case fisheyePrism
    case fresnel, lenticular, axicon, aspheric, astigmatic, coma
    var id: String { rawValue }

    /// Which way the shader bends the picture.
    ///
    /// The first six are all the same manoeuvre with different numbers — the
    /// bend lives in a band along the outline, which is what the system's own
    /// glass does. The five after them are different shapes of glass, and no
    /// choice of amount and height reaches them: a fisheye is radial, a
    /// cylinder works in one axis, a prism splits the channels apart. They are
    /// therefore the shader's business alone. The glass styles, which have only
    /// the private filter to work with, take the approximation in `parameters`
    /// and cannot do better.
    enum Shape: Int32 {
        case edge = 0, convex, concave, fisheye, cylinder, prism
        case reduce, magnify, bevel, ripple, anamorphic
        case fisheyePrism
        case fresnel, lenticular, axicon, aspheric, astigmatic, coma
    }

    var shape: Shape {
        switch self {
        case .convex:   return .convex
        case .concave:  return .concave
        case .fisheye:  return .fisheye
        case .cylinder: return .cylinder
        case .prism:      return .prism
        case .reduce:     return .reduce
        case .magnify:    return .magnify
        case .bevel:      return .bevel
        case .ripple:     return .ripple
        case .anamorphic: return .anamorphic
        case .fisheyePrism: return .fisheyePrism
        case .fresnel:    return .fresnel
        case .lenticular: return .lenticular
        case .axicon:     return .axicon
        case .aspheric:   return .aspheric
        case .astigmatic: return .astigmatic
        case .coma:       return .coma
        default:          return .edge
        }
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .deep:   return "Deep"
        case .sharp:  return "Sharp"
        case .dome:   return "Dome"
        case .frost:  return "Frost"
        case .flat:   return "Flat"
        case .convex:   return "Convex"
        case .concave:  return "Concave"
        case .fisheye:  return "Fisheye"
        case .cylinder: return "Cylinder"
        case .prism:    return "Prism"
        case .reduce:     return "Reduce"
        case .magnify:    return "Magnify"
        case .bevel:      return "Bevel"
        case .ripple:     return "Ripple"
        case .anamorphic: return "Anamorphic"
        case .fisheyePrism: return "Fisheye prism"
        case .fresnel:    return "Fresnel"
        case .lenticular: return "Lenticular"
        case .axicon:     return "Axicon"
        case .aspheric:   return "Aspheric"
        case .astigmatic: return "Astigmatic"
        case .coma:       return "Coma"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Exactly what macOS draws for its own bars: the background bends gently at the rim."
        case .deep:   return "The same bend, several times stronger and spread across the whole cap. What passes under the edge is visibly pulled in."
        case .sharp:  return "A strong bend packed into a narrow band, so the background breaks over the edge rather than curving into it."
        case .dome:   return "Refraction on both sides of the edge — the bar reads as a thicker piece of glass sitting above the page."
        case .frost:  return "A gentle bend behind a much heavier blur. Whatever is underneath stops being readable and becomes texture."
        case .flat:   return "No bend at all: a plain translucent plate. Useful when the bar sits over text that must stay legible."
        case .convex:   return "A magnifying glass: the middle is pushed outwards, so whatever is under the bar comes up larger and the edges crowd together."
        case .concave:  return "The opposite face. The middle is drawn in, the page shrinks away under the bar and more of it fits behind the glass."
        case .fisheye:  return "A magnification that grows towards the middle and dies at the rim, the way a drop of water sits on a page."
        case .cylinder: return "Bent across the short axis only, like a glass rod laid on the page: lines bow as they pass under it and run straight again at the ends."
        case .prism:    return "The three channels bend by different amounts, so the edges break into colour the way a bevel does in sunlight."
        case .reduce:     return "A reducing glass. What is under the bar is pulled down to a third of its size, so a whole paragraph fits behind it."
        case .magnify:    return "The strongest magnification here: a couple of words fill the bar, at two and a half times their size."
        case .bevel:      return "A thick plate with a chamfered edge. The middle is a clear window and all the bending happens in the last few pixels."
        case .ripple:     return "Rings running out from the centre, as though a drop had just landed on the page."
        case .anamorphic: return "Squeezed across the long axis alone: lines keep their height and lose their width, so more of a sentence fits than should."
        case .fisheyePrism: return "Both at once, which is what one piece of real glass does: it magnifies from the middle outwards, and the three colours do not magnify by quite the same amount. The fringe is nothing at the centre and widest at the rim."
        case .fresnel:    return "A lighthouse lens. The curve of a thick piece of glass, cut into concentric rings and collapsed flat, so the bend starts over at every ring."
        case .lenticular: return "A row of glass rods side by side, the way a lenticular print is ruled. Each one bends its own narrow strip, and the seams between them are visible on purpose."
        case .axicon:     return "A cone rather than a dome. The bend is the same everywhere instead of growing from the middle, so the light gathers in a ring rather than a point."
        case .aspheric:   return "A face that is nearly flat in the middle and turns sharply at the rim. Ground this way to cure the blur a plain sphere leaves at its edges."
        case .astigmatic: return "One power across, another down — the shape of a spectacle lens for astigmatism. What is under the bar is stretched one way and squeezed the other."
        case .coma:       return "The comet-shaped smear a lens gives what does not sit on its axis: sharp on one side, trailing on the other, worse the further out it goes."
        }
    }

    /// The inputs to write into `glassBackground`. Empty means "leave it be".
    var parameters: [String: Double] {
        switch self {
        case .system: return [:]
        case .deep:   return ["inputInnerRefractionAmount": -400,
                              "inputInnerRefractionHeight": 46]
        case .sharp:  return ["inputInnerRefractionAmount": -260,
                              "inputInnerRefractionHeight": 10]
        case .dome:   return ["inputInnerRefractionAmount": -200,
                              "inputInnerRefractionHeight": 40,
                              "inputOuterRefractionAmount": -120,
                              "inputOuterRefractionHeight": 24]
        case .frost:  return ["inputInnerRefractionAmount": -40,
                              "inputInnerRefractionHeight": 12,
                              "inputBlurRadius": 26]
        case .flat:   return ["inputInnerRefractionAmount": 0,
                              "inputInnerRefractionHeight": 0]
        // The five below are shapes the private filter has no notion of. What
        // it is given here is the nearest thing in its own vocabulary, so the
        // glass styles change at all when the setting does; only the lens
        // draws them as described.
        case .convex:   return ["inputInnerRefractionAmount": -150,
                                "inputInnerRefractionHeight": 34]
        case .concave:  return ["inputInnerRefractionAmount": -90,
                                "inputInnerRefractionHeight": 30]
        case .fisheye:  return ["inputInnerRefractionAmount": -320,
                                "inputInnerRefractionHeight": 40]
        case .cylinder: return ["inputInnerRefractionAmount": -180,
                                "inputInnerRefractionHeight": 28]
        case .prism:    return ["inputInnerRefractionAmount": -120,
                                "inputInnerRefractionHeight": 14]
        case .reduce:     return ["inputInnerRefractionAmount": -260,
                                  "inputInnerRefractionHeight": 44]
        case .magnify:    return ["inputInnerRefractionAmount": -200,
                                  "inputInnerRefractionHeight": 36]
        case .bevel:      return ["inputInnerRefractionAmount": -300,
                                  "inputInnerRefractionHeight": 6]
        case .ripple:     return ["inputInnerRefractionAmount": -140,
                                  "inputInnerRefractionHeight": 24]
        case .anamorphic: return ["inputInnerRefractionAmount": -170,
                                  "inputInnerRefractionHeight": 30]
        case .fisheyePrism: return ["inputInnerRefractionAmount": -340,
                                    "inputInnerRefractionHeight": 38]
        case .fresnel:    return ["inputInnerRefractionAmount": -220,
                                  "inputInnerRefractionHeight": 16]
        case .lenticular: return ["inputInnerRefractionAmount": -180,
                                  "inputInnerRefractionHeight": 12]
        case .axicon:     return ["inputInnerRefractionAmount": -240,
                                  "inputInnerRefractionHeight": 34]
        case .aspheric:   return ["inputInnerRefractionAmount": -280,
                                  "inputInnerRefractionHeight": 26]
        case .astigmatic: return ["inputInnerRefractionAmount": -200,
                                  "inputInnerRefractionHeight": 30]
        case .coma:       return ["inputInnerRefractionAmount": -260,
                                  "inputInnerRefractionHeight": 32]
        }
    }
}

/// A light or dark bar, independent of the system.
enum BarAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .auto:   return "Auto"
        }
    }

    /// Auto reads the screen to know what it is sitting on, so it wants the
    /// same permission the lens does.
    var needsScreenRecording: Bool { self == .auto }
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
    /// Whether the bar shows this item's icon, its title, or both.
    var label: ActionLabel = .icon

    var isBuiltin: Bool {
        if case .builtin = kind { return true }
        return false
    }

    init(id: UUID = UUID(), title: String, symbol: String, kind: ActionKind,
         context: ActionContext = .anyText, enabled: Bool = true,
         maxTextLength: Int? = nil, label: ActionLabel = .icon) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.context = context
        self.enabled = enabled
        self.maxTextLength = maxTextLength
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, symbol, kind, context, enabled, maxTextLength, label
    }

    /// Decoded by hand so a field added in a later version cannot make the
    /// whole stored list undecodable.
    ///
    /// The synthesised decoder throws on a missing key even where the property
    /// carries a default — measured, not assumed. And load() answers a failed
    /// decode by falling back to the built-in set, so one new field would have
    /// silently wiped every action the user had configured. Only the three
    /// fields that define an item are required; the rest fall back.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title  = try c.decode(String.self, forKey: .title)
        symbol = try c.decode(String.self, forKey: .symbol)
        kind   = try c.decode(ActionKind.self, forKey: .kind)
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        context       = try c.decodeIfPresent(ActionContext.self, forKey: .context) ?? .anyText
        enabled       = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxTextLength = try c.decodeIfPresent(Int.self, forKey: .maxTextLength)
        label         = try c.decodeIfPresent(ActionLabel.self, forKey: .label) ?? .icon
    }
}

/// Settings and the list of items. Stored in UserDefaults.
@MainActor
final class ActionStore: ObservableObject {
    static let shared = ActionStore()

    @Published var definitions: [ActionDefinition] = [] {
        didSet {
            if !regrouping {
                regrouping = true
                lift(after: oldValue)
                regrouping = false
            }
            save()
        }
    }

    /// Set while the list is being rearranged by the line below, so that the
    /// rearrangement does not set it off again.
    private var regrouping = false

    /// Switching an action on lifts it above everything switched off, and
    /// switching one off drops it below everything switched on.
    ///
    /// The list is fifty-odd items and most of them are off, so without this
    /// the handful in use end up scattered through a page of ones that are
    /// not. It costs nothing that matters: the bar reads the same list in the
    /// same order and takes only what is on, so moving an item across the
    /// boundary between on and off cannot change what the bar looks like.
    ///
    /// It moves the one item that changed rather than re-sorting everything,
    /// so an order arranged by hand stays arranged. Anything that is not a
    /// single switch being flipped — an item added, the list reset, a drag —
    /// is left alone.
    private func lift(after old: [ActionDefinition]) {
        guard old.count == definitions.count else { return }
        let before = Dictionary(old.map { ($0.id, $0.enabled) }, uniquingKeysWith: { a, _ in a })
        let switched = definitions.indices.filter {
            guard let was = before[definitions[$0].id] else { return true }
            return was != definitions[$0].enabled
        }
        guard switched.count == 1, let index = switched.first else { return }

        let item = definitions.remove(at: index)
        let target: Int
        if item.enabled {
            // After the last one already on, so it joins the end of the bar
            // rather than jumping ahead of what was already there.
            target = definitions.lastIndex(where: \.enabled).map { $0 + 1 } ?? 0
        } else {
            target = definitions.firstIndex(where: { !$0.enabled }) ?? definitions.count
        }
        definitions.insert(item, at: target)
    }
    @Published var offerPaste = true { didSet { defaults.set(offerPaste, forKey: "offerPaste") } }

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
    /// How solid the bar's background is. The icons are unaffected: the
    /// backdrop and the buttons are siblings, not nested.
    @Published var barOpacity: Double = 0.85 { didSet { defaults.set(barOpacity, forKey: "barOpacity") } }
    @Published var barStyle: BarStyle = .glass { didSet { defaults.set(barStyle.rawValue, forKey: "barStyle") } }
    @Published var barAppearance: BarAppearance = .system { didSet { defaults.set(barAppearance.rawValue, forKey: "barAppearance") } }
    @Published var barLens: BarLens = .system { didSet { defaults.set(barLens.rawValue, forKey: "barLens") } }
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
        barScale = defaults.object(forKey: "barScale") as? Double ?? 1.0
        barOpacity = defaults.object(forKey: "barOpacity") as? Double ?? 0.85
        barStyle = (defaults.string(forKey: "barStyle").flatMap(BarStyle.init)) ?? .glass
        barAppearance = (defaults.string(forKey: "barAppearance").flatMap(BarAppearance.init)) ?? .system
        barLens = (defaults.string(forKey: "barLens").flatMap(BarLens.init)) ?? .system
        barTint = defaults.array(forKey: "barTint") as? [Double]
        launchAtLogin = SMAppService.mainApp.status == .enabled
        load()
    }

    // MARK: - Built-in items

    static let builtinDefaults: [ActionDefinition] = [
        .init(title: "Copy",      symbol: "doc.on.doc",         kind: .builtin("copy")),
        .init(title: "Open",      symbol: "link",               kind: .builtin("open"),   context: .links),
        .init(title: "Email",     symbol: "envelope",           kind: .builtin("email"),  context: .emails),
        .init(title: "Search",    symbol: "magnifyingglass",    kind: .builtin("search"),    context: .plainText),
        .init(title: "Translate", symbol: "translate",          kind: .builtin("translate"), context: .plainText),
        .init(title: "Speak",     symbol: "speaker.wave.2",     kind: .builtin("speak"),     context: .plainText,
              maxTextLength: 800),
        .init(title: "Paste",     symbol: "doc.on.clipboard",   kind: .builtin("paste"), context: .emptyField),
        .init(title: "Paste and go", symbol: "arrow.right.doc.on.clipboard",
              kind: .builtin("pasteGo"), context: .emptyField, enabled: false),
        // Any text, not only editable: selecting all of a page one cannot
        // type into is as much the point as selecting all of a field.
        .init(title: "Select All", symbol: "text.viewfinder",
              kind: .builtin("selectAll"), context: .anyText),

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
        .init(title: "Trim spaces", symbol: "text.word.spacing",
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

        .init(title: "Cut", symbol: "scissors",
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
        .init(title: "Calculate", symbol: "equal.square",
              kind: .builtin("calc"), context: .editableText, enabled: false),

        // --- The system's own services ---
        // What fills the Services submenu of every context menu on the
        // machine. Nothing here is reimplemented: each is the name macOS has
        // registered, handed back to it with the selection on a pasteboard.
        // The panel from a three-finger tap, not the Dictionary application.
        .init(title: "Look Up", symbol: "character.book.closed",
              kind: .builtin("lookUp"), context: .anyText, enabled: false),
        .init(title: "Summarize", symbol: "text.quote",
              kind: .builtin("summarize"), context: .plainText, enabled: false),
        .init(title: "New Sticky", symbol: "note.text",
              kind: .builtin("sticky"), context: .anyText, enabled: false),
        .init(title: "New Email", symbol: "envelope.open",
              kind: .builtin("mailSelection"), context: .anyText, enabled: false),
        // Not a document glyph: beside Look Up's closed book it was one more
        // small rectangle with lines in it, and the two sat four apart in a
        // row of fourteen.
        .init(title: "Open in TextEdit", symbol: "square.and.pencil",
              kind: .builtin("textEdit"), context: .anyText, enabled: false),
        .init(title: "Show Map", symbol: "map",
              kind: .builtin("showMap"), context: .plainText, enabled: false),
        .init(title: "Reading List", symbol: "list.star",
              kind: .builtin("readingList"), context: .links, enabled: false),

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

        // A changed catalogue symbol does not reach a stored item either: the
        // old glyph is what comes back. Each entry names the glyph the
        // catalogue used to ship, so an item whose symbol the user picked
        // themselves is left alone — the field is editable in settings, and an
        // unconditional refresh would quietly overwrite their choice.
        //
        // Built-in items are matched on their stable id, the rest by title for
        // want of one. Retiring the whole batch on a single flag is safe: an
        // entry whose rename has already happened no longer matches its old
        // glyph and does nothing.
        let symbolRefreshKey = "symbolRefresh.v4"
        if !defaults.bool(forKey: symbolRefreshKey) {
            let renames: [(matches: (ActionDefinition) -> Bool, was: String, now: String)] = [
                (matches: {
                    if case .builtin(let id) = $0.kind { return id == "open" }
                    return false
                }, was: "safari", now: "link"),
                (matches: { $0.title == "Claude" }, was: "sparkles", now: "asterisk"),
                // Scissors are what everyone's Cut is drawn with. They had
                // been spent on trimming whitespace, which was a pun rather
                // than a meaning.
                (matches: {
                    if case .builtin(let id) = $0.kind { return id == "cut" }
                    return false
                }, was: "scissors.circle", now: "scissors"),
                (matches: {
                    if case .builtin(let id) = $0.kind { return id == "trim" }
                    return false
                }, was: "scissors", now: "text.word.spacing"),
                (matches: {
                    if case .builtin(let id) = $0.kind { return id == "textEdit" }
                    return false
                }, was: "doc.richtext", now: "square.and.pencil"),
            ]
            for rename in renames {
                guard let index = stored.firstIndex(where: {
                    rename.matches($0) && $0.symbol == rename.was
                }) else { continue }
                stored[index].symbol = rename.now
            }
            defaults.set(true, forKey: symbolRefreshKey)
        }

        // Once: everything switched on to the top, so the handful in use are
        // not scattered through fifty that are not. A stable partition — the
        // bar reads this same list in order and takes only what is on, so it
        // comes out exactly as it was. Once rather than on every launch,
        // because an order arranged by hand is the owner's to keep.
        let groupKey = "groupedEnabled.v1"
        if !defaults.bool(forKey: groupKey) {
            stored = stored.filter(\.enabled) + stored.filter { !$0.enabled }
            defaults.set(true, forKey: groupKey)
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
        // Read the pasteboard only if something is going to ask about it. The
        // paste item is the only one that does, it is shown only where typing
        // is allowed, and it is off by default — so most selections used to
        // copy the whole pasteboard across for nothing.
        let wantsClipboard = editable && definitions.contains {
            $0.enabled && $0.context == .emptyField
        }
        let clip = wantsClipboard ? clipboardPreview() : nil
        return definitions
            .filter { def in
                guard def.enabled, Self.canBeOpened(def) else { return false }
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

    /// Whether anything on this machine can open what an item points at.
    ///
    /// A handful of items address an application directly — bear://,
    /// things://, obsidian:// — and on a machine without that application they
    /// are buttons that do nothing whatever. Nothing reports the failure
    /// either: the open is handed to the system and the system shrugs. Better
    /// to leave them out of the bar, and leave them in the list so that
    /// installing the application is all it takes.
    ///
    /// Only the direct ones are asked about. A web address always has
    /// something to open it, and asking would be a launch-services lookup per
    /// item per showing for an answer that is always yes.
    private static var openers: [String: Bool] = [:]
    private static func canBeOpened(_ def: ActionDefinition) -> Bool {
        guard case .openURL(let template) = def.kind else { return true }
        guard let url = URL(string: template.replacingOccurrences(of: "{text}", with: "x")),
              let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" { return true }
        if let known = openers[scheme] { return known }
        let found = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        openers[scheme] = found
        return found
    }

    /// The start of the pasteboard contents, for the paste button's tooltip.
    ///
    /// Cut to length before it is tidied, not after. Only the first forty
    /// characters are ever shown, and trimming and replacing newlines across a
    /// pasteboard holding a whole document — which is exactly what a pasteboard
    /// often holds — built two more copies of it to throw both away.
    private func clipboardPreview() -> String? {
        guard let clip = NSPasteboard.general.string(forType: .string) else { return nil }

        // One character more than is shown, so that a pasteboard sitting
        // exactly on the limit is not marked as continuing. Leading blanks go
        // first, or a pasteboard beginning with a run of them would preview as
        // empty.
        let limit = 40
        let head = String(clip.drop { $0.isWhitespace }.prefix(limit + 1))
        // Decided before tidying, not after: trimming can take the string back
        // under the limit, and the ellipsis would then go missing from a
        // pasteboard that does carry on.
        let continues = head.count > limit
        let shown = head.prefix(limit)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty else { return nil }
        return continues ? shown + "…" : shown
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
                          run: run, tooltip: tooltip, label: def.label)
        case .openURL(let template):
            return Action(title: def.title, symbol: def.symbol,
                          run: { text in
                              let url = template.replacingOccurrences(
                                  of: "{text}", with: Action.urlEncoded(text))
                              Action.open(url)
                          }, tooltip: tooltip, label: def.label)
        case .shell(let command):
            return Action(title: def.title, symbol: def.symbol,
                          run: { text in Action.runShell(command, text: text) },
                          tooltip: tooltip, label: def.label)
        }
    }
}

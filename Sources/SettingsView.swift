import SwiftUI

/// Where in the settings we are.
///
/// Tabs used to sit at the top and switch between two flat pages. A path with
/// a root replaces them: the editor for a single action was already a third
/// level pretending to be part of the second, and the breadcrumb says out loud
/// what the back button could only imply.
enum SettingsPage: Hashable {
    case root
    case appearance
    case behaviour
    case actions
    case editor(UUID)
}

struct SettingsView: View {
    @ObservedObject var store: ActionStore

    @State private var page: SettingsPage = .root
    /// Asked once when the page appears rather than on every redraw: the check
    /// crosses into the window server, and this view redraws on every drag of
    /// a slider.
    @State private var screenRecordingGranted = true
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            CrumbBar(crumbs: crumbs) { index in
                // Only the root is ever a target: the path is never deeper
                // than three, and the middle crumb of the editor is the list
                // it was opened from.
                page = index == 0 ? .root : .actions
                query = ""
            }
            Hairline()

            // The search field is the only thing this row ever holds, and it
            // belongs to the Actions list alone — four dozen rows deep and the
            // one page where finding something takes work. Everywhere else the
            // row would be empty, so it is not drawn at all.
            if page == .actions {
                SearchRow(text: $query, placeholder: "Search actions",
                          focused: $searchFocused) { EmptyView() }
                Hairline()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Chrome.width, height: Chrome.height)
        .background(shortcuts)
        .onAppear { screenRecordingGranted = ScreenPhoto.permitted }
    }

    // MARK: - Chrome

    private var crumbs: [String] {
        switch page {
        case .root:       return ["Settings"]
        case .appearance: return ["Settings", "Appearance"]
        case .behaviour:  return ["Settings", "Behaviour"]
        case .actions:    return ["Settings", "Actions"]
        case .editor(let id):
            let title = store.definitions.first { $0.id == id }?.title ?? "Item"
            return ["Settings", "Actions", title.isEmpty ? "Untitled" : title]
        }
    }

    /// The shortcuts are not advertised anywhere in the panel — ⌘F for the
    /// search field, ⌘[ back a level, Escape to close, the last one caught by
    /// the panel's own monitor. They still work; they are parked behind the
    /// panel where they cannot be seen. A Button is the only way to bind a key
    /// without a menu.
    private var shortcuts: some View {
        ZStack {
            Button("") {
                if page == .actions {
                    searchFocused = true
                } else {
                    // The only search there is belongs to the Actions list, so
                    // the key goes there rather than doing nothing. The field
                    // does not exist until that page has been built, and focus
                    // set in the same turn of the run loop lands on nothing.
                    page = .actions
                    DispatchQueue.main.async { searchFocused = true }
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("") {
                if case .editor = page { page = .actions } else { page = .root }
                query = ""
            }
            .keyboardShortcut("[", modifiers: .command)
        }
        // Invisible, but not zero-sized and not .hidden(): a view taken out of
        // the layout stops answering its shortcut. Sitting in a background it
        // costs the panel no space either way.
        .opacity(0)
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .root:       rootPage
        case .appearance: appearancePage
        case .behaviour:  behaviourPage
        case .actions:    ActionsPage(store: store, query: query, page: $page)
        case .editor(let id):
            if let index = store.definitions.firstIndex(where: { $0.id == id }) {
                EditorPage(store: store, index: index, page: $page)
            } else {
                // The item was deleted from under us.
                Color.clear.onAppear { page = .actions }
            }
        }
    }

    private var rootPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                NavRow(title: "Appearance",
                       subtitle: "Size, style, theme and tint",
                       symbol: "paintbrush") { page = .appearance }
                NavRow(title: "Behaviour",
                       subtitle: "Login, menu bar icon, keyboard blink",
                       symbol: "switch.2") { page = .behaviour }
                NavRow(title: "Actions",
                       subtitle: "What the bar offers, and in what order",
                       symbol: "list.bullet",
                       badge: "\(store.definitions.filter(\.enabled).count)/\(store.definitions.count)") {
                    page = .actions
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var appearancePage: some View {
        VStack(spacing: 0) {
            appearanceControls
            Hairline()
            // Pinned below the controls rather than left as the last section
            // of the scroll: every setting above it changes what it shows, and
            // a preview you have to scroll to is a preview you miss.
            preview
        }
    }

    /// The bar as these settings will draw it.
    private var preview: some View {
        VStack(spacing: 0) {
            Text("Preview")
                .font(.system(size: 12))
                .foregroundStyle(Chrome.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Chrome.gutter)
                .padding(.top, 10)

            BarPreview(style: store.barStyle,
                       lens: store.barLens,
                       appearance: store.barAppearance,
                       scale: store.barScale,
                       opacity: store.barOpacity,
                       tint: store.barTint)
                .frame(maxWidth: .infinity)
                // Fixed, so the strip does not resize under the pointer while
                // the size slider is being dragged. Tall enough for the bar at
                // its largest.
                .frame(height: 78)
        }
        .background(Chrome.band)
    }

    private var appearanceControls: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionHeader(title: "Bar appearance")

                SliderRow(title: "Size", value: $store.barScale, in: 0.7...1.8)
                SliderRow(title: "Opacity", value: $store.barOpacity, in: 0.3...1,
                          enabled: !glassStyle)
                if glassStyle {
                    HintText(text: "Glass carries its own translucency; fading it would switch the effect off.")
                }

                SettingRow(title: "Style") {
                    Segmented(options: BarStyle.allCases.map { ($0, shortTitle($0)) },
                              selection: $store.barStyle)
                }
                SettingRow(title: "Tap when it appears",
                           subtitle: "A click of the trackpad under the finger as the bar arrives. Trackpads without a haptic engine feel nothing.",
                           toggle: $store.hapticOnShow)
                SettingRow(title: "Tap on each action",
                           subtitle: "As the pointer crosses onto an action. Sweeping the bar then counts the actions under the finger without looking.",
                           toggle: $store.hapticOnHover)
                if store.hapticOnShow || store.hapticOnHover {
                    SettingRow(title: "Strength") {
                        Segmented(options: HapticStrength.allCases.map { ($0, $0.title) },
                                  selection: $store.hapticStrength)
                    }
                }
                SettingRow(title: "Shows") {
                    Segmented(options: BarAnchor.allCases.map { ($0, $0.title) },
                              selection: $store.barAnchor)
                }
                if store.barAnchor == .selection {
                    HintText(text: "Centred over the selected text, whichever way it was dragged. Where an application will not say where its text is, the pointer stands in.")
                }
                SettingRow(title: "Theme") {
                    Segmented(options: BarAppearance.allCases.map { ($0, $0.title) },
                              selection: $store.barAppearance)
                }
                if store.barAppearance == .auto {
                    HintText(text: "The bar reads what it is about to cover and takes the same side: dark over a dark page, light over a light one. It needs Screen Recording for that, and falls back to the system's setting without it.")
                }
                // Refraction reaches both routes: the glass styles write the
                // numbers into the system's own filter, the lens hands the
                // same ones to its shader.
                if glassStyle || store.barStyle == .lens {
                    // A dropdown rather than a segmented control: there are
                    // eleven of these now, and a row of eleven would be
                    // unreadable long before it stopped fitting.
                    StyledPicker(title: "Refraction",
                                 options: BarLens.allCases.map { ($0, $0.title) },
                                 selection: $store.barLens)
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.text)
                        .padding(.horizontal, Chrome.gutter)
                        .padding(.vertical, 7)
                    HintText(text: store.barLens.detail)
                    if store.barStyle != .lens, store.barLens.shape != .edge {
                        HintText(text: "Only the Lens style draws this shape. The glass styles are drawn by the system, whose own refraction has no notion of it, and take the nearest approximation.")
                    }
                }

                if store.barStyle == .lens {
                    SectionHeader(title: "Lens")
                    HintText(text: "The bar photographs what is behind it and bends the picture in a shader of its own. Unlike the glass styles, which the window server draws, this needs Screen Recording — and macOS keeps its purple indicator lit in the menu bar while the bar is up.")
                }

                // One row for both, since both read the screen and there is
                // only one permission between them.
                if readsTheScreen, !screenRecordingGranted {
                    SectionHeader(title: "Permission")
                    SettingRow(title: "Screen Recording is not granted",
                               subtitle: "Without it the lens falls back to a plain fill and Auto to the system's theme. macOS applies the permission on the next launch.") {
                        PillButton(title: "Grant…") {
                            ScreenPhoto.requestPermission()
                        }
                    }
                }

                SectionHeader(title: "Tint")
                SettingRow(title: "Tint the background", toggle: useTint)
                if store.barTint != nil {
                    SettingRow(title: "Colour") {
                        ColorPicker("", selection: tint, supportsOpacity: true)
                            .labelsHidden()
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var behaviourPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionHeader(title: "System")
                SettingRow(title: "Launch at login", toggle: $store.launchAtLogin)
                SettingRow(title: "Show icon in the menu bar",
                           subtitle: "Hidden, the only way back is to launch the app again.",
                           toggle: $store.showStatusIcon)

            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Bindings

    /// Whether anything currently switched on wants to look at the screen.
    private var readsTheScreen: Bool {
        store.barStyle.needsScreenRecording || store.barAppearance.needsScreenRecording
    }

    private var glassStyle: Bool {
        store.barStyle == .glass || store.barStyle == .glassClear
    }

    /// The catalogue titles are spelled out for the Actions list; a segmented
    /// control has no room for "Glass (clear)".
    private func shortTitle(_ style: BarStyle) -> String {
        switch style {
        case .solid:      return "Solid"
        case .glass:      return "Glass"
        case .glassClear: return "Clear"
        case .blur:       return "Blur"
        case .lens:       return "Lens"
        }
    }

    /// The tint is stored as sRGB components while SwiftUI wants a Color,
    /// so we convert both ways on the fly.
    private var tint: Binding<Color> {
        Binding(
            get: {
                guard let c = store.barTint, c.count == 4 else { return .accentColor }
                return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? .controlAccentColor
                store.barTint = [Double(ns.redComponent), Double(ns.greenComponent),
                                 Double(ns.blueComponent), Double(ns.alphaComponent)]
            }
        )
    }

    private var useTint: Binding<Bool> {
        Binding(
            get: { store.barTint != nil },
            set: { on in store.barTint = on ? [0.0, 0.48, 1.0, 0.35] : nil }
        )
    }
}

// MARK: - The bar, as these settings will draw it

/// The live bar, embedded in the settings panel.
///
/// It is built by the very code that builds the real one — see
/// `PopupController.previewBar`. An imitation drawn a second way would drift
/// from the bar the first time either was touched.
@MainActor
private struct BarPreview: NSViewRepresentable {
    // Stated rather than inferred: the builder is main-actor isolated, and
    // without the annotation above the conformance is not satisfied at all,
    // whereupon this type can no longer be worked out either.
    typealias NSViewType = NSView

    /// Every setting the bar is drawn from, taken by value.
    ///
    /// The builder reads the store itself, so these are not what it draws
    /// from; they are here so SwiftUI has something to compare. Left out, the
    /// view would be built once and never asked to change again — the store is
    /// not part of what SwiftUI diffs.
    let style: BarStyle
    let lens: BarLens
    let appearance: BarAppearance
    let scale: Double
    let opacity: Double
    let tint: [Double]?

    @MainActor
    final class Coordinator {
        /// Never shown. It exists to build views and to be the target of
        /// buttons that must do nothing.
        let builder = PopupController()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // The context type is spelled out rather than written as `Context`. That
    // shorthand is the protocol's, but the app has an enum of its own by that
    // name — what is under the cursor, in Selection.swift — and being a
    // top-level type it wins. The methods then took the wrong type, satisfied
    // nothing, and the conformance failed with the two signatures printed
    // side by side looking identical.
    func makeNSView(context: NSViewRepresentableContext<BarPreview>) -> NSView {
        let host = NSView()
        rebuild(host, with: context.coordinator)
        return host
    }

    func updateNSView(_ host: NSView, context: NSViewRepresentableContext<BarPreview>) {
        rebuild(host, with: context.coordinator)
    }

    private func rebuild(_ host: NSView, with coordinator: Coordinator) {
        host.subviews.forEach { $0.removeFromSuperview() }

        let bar = coordinator.builder.previewBar(actions: sample)

        // With the theme set to System the builder leaves the appearance
        // unset, so the view takes it from whatever it is placed in. The real
        // bar is placed in a window of its own and inherits the application's;
        // here it would inherit the settings panel's, which is forced dark —
        // and a light system would preview as dark. So it is stated outright.
        if appearance == .system {
            bar.appearance = NSApp.effectiveAppearance
        }

        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
    }

    /// A fixed trio rather than whatever happens to be enabled.
    ///
    /// The preview is about the style, and a bar that changed width every time
    /// an action was switched on elsewhere would jump about for no reason the
    /// eye could follow. Icons only for the same reason: a label can run to any
    /// length, and this strip has a fixed width to sit in.
    ///
    /// A computed property rather than a static one: an Action carries
    /// closures, so a stored global of them would not be concurrency-safe.
    private var sample: [Action] {
        [
            Action(title: "Copy", symbol: "doc.on.doc",
                   run: { _ in }),
            Action(title: "Search", symbol: "magnifyingglass",
                   run: { _ in }),
            Action(title: "Translate", symbol: "translate",
                   run: { _ in }),
        ]
    }
}

/// A symbol that is missing from this system's catalogue would leave a blank
/// row, so it is swapped for a visible placeholder.
func symbolOrFallback(_ name: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        ? name : "questionmark.square.dashed"
}

// MARK: - The list of actions

private struct ActionsPage: View {
    @ObservedObject var store: ActionStore
    let query: String
    @Binding var page: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            if query.isEmpty {
                // Only the unfiltered list can be reordered: onMove hands back
                // offsets into what is on screen, and against a filtered list
                // they point at the wrong items.
                List {
                    ForEach($store.definitions) { $def in
                        row($def)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in
                        store.definitions.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 34)
            } else {
                filtered
            }

            Hairline()
            HStack(spacing: 8) {
                PillButton(title: "Add item", symbol: "plus") { addAction() }
                Spacer()
                PillButton(title: "Reset all") { store.resetToDefaults() }
            }
            .padding(.horizontal, Chrome.gutter)
            .padding(.vertical, 8)
        }
    }

    private var filtered: some View {
        let needle = query.lowercased()
        let indices = store.definitions.indices.filter {
            store.definitions[$0].title.lowercased().contains(needle)
        }
        return ScrollView {
            VStack(spacing: 0) {
                if indices.isEmpty {
                    Text("No action matches “\(query)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Chrome.gutter)
                        .padding(.top, 18)
                } else {
                    ForEach(indices, id: \.self) { index in
                        row($store.definitions[index])
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ def: Binding<ActionDefinition>) -> some View {
        ActionRow(def: def) { page = .editor(def.wrappedValue.id) }
    }

    private func addAction() {
        let new = ActionDefinition(title: "New item", symbol: "star",
                                   kind: .openURL("https://example.com/?q={text}"))
        // With the rest of what is switched on, not below everything that is
        // off: a new item arrives switched on, so that is where it belongs.
        let target = store.definitions.lastIndex(where: \.enabled).map { $0 + 1 } ?? 0
        store.definitions.insert(new, at: target)
        page = .editor(new.id)
    }
}

/// One line of the action list: the switch, the icon, the title, and the way in.
private struct ActionRow: View {
    @Binding var def: ActionDefinition
    let edit: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $def.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.white.opacity(0.34))
            Image(systemName: symbolOrFallback(def.symbol))
                .font(.system(size: 12))
                .foregroundStyle(def.enabled ? Chrome.text : Chrome.faint)
                .frame(width: 18)
            Text(def.title.isEmpty ? "Untitled" : def.title)
                .font(.system(size: 13))
                .foregroundStyle(def.enabled ? Chrome.text : Chrome.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(def.context.shortTitle)
                .font(.system(size: 11))
                .foregroundStyle(Chrome.faint)
                .lineLimit(1)
            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.faint)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Chrome.gutter)
        .padding(.vertical, 6)
        .background(hovered ? Chrome.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

extension ActionContext {
    /// The full titles read as sentences, which is right in a picker and far
    /// too long at the end of a list row.
    var shortTitle: String {
        switch self {
        case .anyText:      return "Any"
        case .plainText:    return "Plain"
        case .links:        return "Links"
        case .emails:       return "Email"
        case .emptyField:   return "Field"
        case .editableText: return "Editable"
        }
    }
}

// MARK: - Editing one action

private struct EditorPage: View {
    @ObservedObject var store: ActionStore
    let index: Int
    @Binding var page: SettingsPage

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionHeader(title: "Item")
                FieldRow(title: "Title", text: $store.definitions[index].title,
                         placeholder: "Untitled")
                FieldRow(title: "Symbol", text: $store.definitions[index].symbol,
                         placeholder: "star")

                SettingRow(title: "Shows") {
                    Segmented(options: [(ActionLabel.icon, "Icon"),
                                        (.iconAndText, "Both"),
                                        (.text, "Label")],
                              selection: $store.definitions[index].label)
                }
                StyledPicker(title: "Show for",
                             options: ActionContext.allCases.map { ($0, $0.title) },
                             selection: $store.definitions[index].context)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.text)
                    .padding(.horizontal, Chrome.gutter)
                    .padding(.vertical, 7)

                SectionHeader(title: "Behaviour")
                if store.definitions[index].isBuiltin {
                    HintText(text: "A built-in action. Its title, symbol and the places it appears can be changed; what it does cannot.")
                } else {
                    SettingRow(title: "Type") {
                        Segmented(options: [("url", "Open URL"), ("shell", "Shell")],
                                  selection: kindTag)
                    }
                    FieldRow(title: "Template", text: templateBinding,
                             placeholder: kindTag.wrappedValue == "url"
                                 ? "https://example.com/?q={text}" : "echo {text}")
                    HintText(text: kindTag.wrappedValue == "url"
                             ? "{text} is replaced with the selection, URL-encoded."
                             : "{text} is quoted for the shell; SB_TEXT holds the raw selection.")

                    HStack {
                        Spacer()
                        PillButton(title: "Delete item", symbol: "trash",
                                   isDestructive: true) {
                            store.definitions.remove(at: index)
                            page = .actions
                        }
                    }
                    .padding(.horizontal, Chrome.gutter)
                    .padding(.top, 10)
                }
            }
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }

    private var kindTag: Binding<String> {
        Binding(
            get: {
                if case .shell = store.definitions[index].kind { return "shell" }
                return "url"
            },
            set: { newValue in
                let current = templateBinding.wrappedValue
                store.definitions[index].kind =
                    newValue == "shell" ? .shell(current) : .openURL(current)
            }
        )
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: {
                switch store.definitions[index].kind {
                case .openURL(let t), .shell(let t): return t
                case .builtin: return ""
                }
            },
            set: { newValue in
                switch store.definitions[index].kind {
                case .shell:   store.definitions[index].kind = .shell(newValue)
                case .openURL: store.definitions[index].kind = .openURL(newValue)
                case .builtin: break
                }
            }
        )
    }
}

// MARK: - The window

/// The settings window. The app lives in the menu bar, so the window is shown
/// by hand and we bring the process to the front ourselves.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var escapeMonitor: Any?

    func show() {
        if window == nil {
            // Borderless, so the window carries the same chrome as the panel
            // under the icon. A title bar would put a system-drawn strip above
            // our rounded corners and break the shape.
            let hosting = NSHostingView(
                rootView: AnyView(SettingsView(store: .shared).panelChrome())
            )
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

            let w = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.contentView = hosting
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isReleasedWhenClosed = false
            // Without a title bar there is nothing to drag, so the background
            // itself moves the window, and Escape stands in for the close box.
            w.isMovableByWindowBackground = true
            w.center()
            window = w

            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                guard event.keyCode == 53 else { return event }   // 53 = Escape
                MainActor.assumeIsolated { [weak self] in self?.close() }
                return nil
            }
        }
        // As with the panels, and settled on every showing rather than once:
        // the preview inside is a lens when the bar is, and must not be shown
        // the window it is standing in. The window outlives a change of style.
        window?.sharingType = ActionStore.shared.windowSharing
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        window?.orderOut(nil)
        window = nil
    }
}

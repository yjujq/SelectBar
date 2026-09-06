import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ActionStore
    @State private var tab: Tab = .general

    private enum Tab: Hashable { case general, actions }

    var body: some View {
        VStack(spacing: 0) {
            // Our own switcher instead of TabView's: that one hugs the window
            // title in the centre, and we want full width and lower down.
            //
            // And our own row of buttons instead of a segmented Picker: that
            // one shows only the title of a Label and drops the image, so an
            // icon next to the text is impossible with it.
            HStack(spacing: 4) {
                TabButton(title: "General", symbol: "gearshape",
                          selected: tab == .general) { tab = .general }
                TabButton(title: "Actions", symbol: "list.bullet",
                          selected: tab == .actions) { tab = .actions }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Divider()

            switch tab {
            case .general: GeneralTab(store: store)
            case .actions: ActionsTab(store: store)
            }
        }
        .frame(width: 300, height: 420)
    }
}

/// A tab button: icon and title side by side, across the available width.
private struct TabButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
            )
            // Otherwise the click only registers on the letters and the icon.
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct GeneralTab: View {
    @ObservedObject var store: ActionStore

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

    var body: some View {
        Form {
            Section("Bar appearance") {
                HStack {
                    Text("Size")
                    Slider(value: $store.barScale, in: 0.7...1.8, step: 0.05)
                    Text("\(Int(store.barScale * 100))%")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                // Glass is left out: fading it switches the effect off
                // entirely, so the control would be worse than useless there.
                let glassStyle = store.barStyle == .glass || store.barStyle == .glassClear
                HStack {
                    Text("Opacity")
                    Slider(value: $store.barOpacity, in: 0.3...1, step: 0.05)
                    Text("\(Int(store.barOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .disabled(glassStyle)
                if glassStyle {
                    Text("Glass carries its own translucency; fading it would switch the effect off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StyledPicker(title: "Style",
                             options: BarStyle.allCases.map { ($0, $0.title) },
                             selection: $store.barStyle)
                StyledPicker(title: "Theme",
                             options: BarAppearance.allCases.map { ($0, $0.title) },
                             selection: $store.barAppearance)
                Toggle("Tint", isOn: useTint)
                if store.barTint != nil {
                    ColorPicker("Tint colour", selection: tint, supportsOpacity: true)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                Toggle("Show icon in the menu bar", isOn: $store.showStatusIcon)
                Toggle("Blink the keyboard on notifications", isOn: $store.blinkOnNotification)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
    }
}

private struct ActionsTab: View {
    @ObservedObject var store: ActionStore
    @State private var editing: UUID?

    var body: some View {
        // Editing replaces the list in place rather than opening a modal
        // sheet: that one was left without a parent when the popover closed
        // and hung the whole settings window.
        if let id = editing, let index = store.definitions.firstIndex(where: { $0.id == id }) {
            editor(index)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List {
                ForEach($store.definitions) { $def in
                    HStack(spacing: 6) {
                        Toggle("", isOn: $def.enabled)
                            .labelsHidden()
                            .controlSize(.small)
                        Image(systemName: symbolOrFallback(def.symbol))
                            .frame(width: 16)
                        Text(def.title.isEmpty ? "Untitled" : def.title)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            editing = def.id
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .onMove { from, to in
                    store.definitions.move(fromOffsets: from, toOffset: to)
                }
            }
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 6) {
                Button { addAction() } label: { Image(systemName: "plus") }
                    .help("Add a custom item")
                Spacer()
                Button("Reset") { store.resetToDefaults() }
            }
            .controlSize(.small)
            .padding(6)
        }
    }

    private func editor(_ index: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    editing = nil
                } label: {
                    Label("Actions", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if !store.definitions[index].isBuiltin {
                    Button("Delete", role: .destructive) {
                        store.definitions.remove(at: index)
                        editing = nil
                    }
                }
            }
            .controlSize(.small)
            .padding(8)

            Divider()

            Form {
                Section {
                    TextField("Title", text: $store.definitions[index].title)
                    TextField("SF Symbol", text: $store.definitions[index].symbol)
                    StyledPicker(title: "Show in the bar",
                                 options: ActionLabel.allCases.map { ($0, $0.title) },
                                 selection: $store.definitions[index].label)
                    StyledPicker(title: "Show for",
                                 options: ActionContext.allCases.map { ($0, $0.title) },
                                 selection: $store.definitions[index].context)
                }
                Section("Behaviour") {
                    if store.definitions[index].isBuiltin {
                        Text("Built-in action").foregroundStyle(.secondary)
                    } else {
                        StyledPicker(title: "Type",
                                     options: [("url", "Open URL"),
                                               ("shell", "Shell command")],
                                     selection: kindTag(index))
                        TextField(kindTag(index).wrappedValue == "url"
                                  ? "https://example.com/?q={text}" : "echo {text}",
                                  text: templateBinding(index))
                        Text(kindTag(index).wrappedValue == "url"
                             ? "{text} is replaced with the selection, URL-encoded."
                             : "{text} is quoted for the shell; SB_TEXT holds the raw selection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func symbolOrFallback(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            ? name : "questionmark.square.dashed"
    }

    private func addAction() {
        let new = ActionDefinition(title: "New item", symbol: "star",
                                   kind: .openURL("https://example.com/?q={text}"))
        store.definitions.append(new)
        editing = new.id
    }

    private func kindTag(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                if case .shell = store.definitions[index].kind { return "shell" }
                return "url"
            },
            set: { newValue in
                let current = templateBinding(index).wrappedValue
                store.definitions[index].kind = newValue == "shell" ? .shell(current) : .openURL(current)
            }
        )
    }

    private func templateBinding(_ index: Int) -> Binding<String> {
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

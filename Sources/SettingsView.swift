import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ActionStore

    var body: some View {
        TabView {
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            ActionsTab(store: store)
                .tabItem { Label("Actions", systemImage: "list.bullet") }
        }
        .frame(width: 620, height: 460)
    }
}

private struct GeneralTab: View {
    @ObservedObject var store: ActionStore

    /// Оттенок хранится компонентами sRGB, а SwiftUI хочет Color —
    /// переводим в обе стороны на лету.
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
                Picker("Style", selection: $store.barStyle) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Theme", selection: $store.barAppearance) {
                    ForEach(BarAppearance.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Tint", isOn: useTint)
                if store.barTint != nil {
                    ColorPicker("Tint colour", selection: tint, supportsOpacity: true)
                }
                Text("Changes apply the next time the bar appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                Toggle("Show icon in the menu bar", isOn: $store.showStatusIcon)
                if !store.showStatusIcon {
                    Text("The icon is hidden. To get back here, open SelectBar again from Finder — that reopens this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Blink keyboard on incoming notifications", isOn: $store.blinkOnNotification)
                Toggle("Blink keyboard on every space press", isOn: $store.blinkOnSpace)
                if store.blinkOnSpace {
                    Text("Space is pressed constantly while typing, so the backlight will flicker for as long as you write.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !InputMonitoring.granted {
                        HStack {
                            Text("Input Monitoring is not granted — key presses are not visible.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open…") { InputMonitoring.openSettings() }
                        }
                        Text("After granting it, quit and start SelectBar again — macOS applies this permission only on launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Show paste bar on double-click in empty fields", isOn: $store.offerPaste)
                Text("SelectBar reads selections through the Accessibility API only. Apps that do not expose their selection will not show the bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ActionsTab: View {
    @ObservedObject var store: ActionStore
    @State private var selection: UUID?

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return store.definitions.firstIndex { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($store.definitions) { $def in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $def.enabled).labelsHidden()
                            Image(systemName: symbolOrFallback(def.symbol))
                                .frame(width: 18)
                            Text(def.title.isEmpty ? "Untitled" : def.title)
                            Spacer()
                            if !def.isBuiltin {
                                Text("custom").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(def.id)
                    }
                    .onMove { from, to in
                        store.definitions.move(fromOffsets: from, toOffset: to)
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Button { addAction() } label: { Image(systemName: "plus") }
                        .help("Add a custom item")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .help("Remove the selected custom item")
                        .disabled(selectedIndex.map { store.definitions[$0].isBuiltin } ?? true)
                    Spacer()
                    Button("Reset") { store.resetToDefaults(); selection = nil }
                }
                .padding(8)
            }
            .frame(minWidth: 240)

            detail.frame(minWidth: 300)
        }
    }

    @ViewBuilder private var detail: some View {
        if let index = selectedIndex {
            Form {
                Section {
                    TextField("Title", text: $store.definitions[index].title)
                    TextField("SF Symbol", text: $store.definitions[index].symbol)
                    HStack {
                        Text("Preview")
                        Spacer()
                        Image(systemName: symbolOrFallback(store.definitions[index].symbol))
                    }
                    Picker("Show for", selection: $store.definitions[index].context) {
                        ForEach(ActionContext.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section("Behaviour") {
                    if store.definitions[index].isBuiltin {
                        Text("Built-in action").foregroundStyle(.secondary)
                    } else {
                        Picker("Type", selection: kindTag(index)) {
                            Text("Open URL").tag("url")
                            Text("Shell command").tag("shell")
                        }
                        if kindTag(index).wrappedValue == "url" {
                            TextField("https://example.com/?q={text}", text: templateBinding(index))
                            Text("{text} is replaced with the selection, URL-encoded.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("echo {text} | pbcopy", text: templateBinding(index))
                            Text("{text} is quoted for the shell; SB_TEXT holds the raw selection.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            VStack {
                Spacer()
                Text("Select an item").foregroundStyle(.secondary)
                Spacer()
            }
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
        selection = new.id
    }

    private func removeSelected() {
        guard let index = selectedIndex, !store.definitions[index].isBuiltin else { return }
        store.definitions.remove(at: index)
        selection = nil
    }

    /// Тип пользовательского пункта — отдельной привязкой, потому что
    /// он хранится как перечисление со связанным значением.
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

/// Окно настроек. Приложение живёт в строке меню, поэтому окно показываем
/// вручную и сами выводим программу на передний план.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: .shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "SelectBar Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

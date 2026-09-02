import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ActionStore
    @State private var tab: Tab = .general

    private enum Tab: Hashable { case general, actions }

    var body: some View {
        VStack(spacing: 0) {
            // Свой переключатель вместо стандартного у TabView: тот жмётся
            // к заголовку окна по центру, а нужен во всю ширину и ниже.
            //
            // И вместо сегментированного Picker — свой ряд кнопок: тот
            // показывает у Label только подпись, а картинку отбрасывает,
            // поэтому иконку рядом с текстом им не получить.
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

/// Кнопка вкладки: иконка и подпись рядом, во всю доступную ширину.
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
            // Иначе нажатие ловится только по самим буквам и значку.
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
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
        // Правка показывается на месте списка, а не отдельной модальной
        // панелью: та при закрытии выпадающего окна оставалась без родителя
        // и подвешивала настройки целиком.
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

            // Прозрачность: размытие вместо сплошной заливки окна.
            // Подложки внутри уже прозрачны (.scrollContentBackground(.hidden)),
            // поэтому сквозь них видно именно это размытие, а не серый фон.
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]

            let host = hosting.view
            host.autoresizingMask = [.width, .height]
            host.frame = blur.bounds
            blur.frame = host.frame
            host.removeFromSuperview()
            blur.addSubview(host)
            w.contentView = blur

            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

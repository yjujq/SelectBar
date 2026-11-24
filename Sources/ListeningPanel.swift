import AppKit
import Speech
import SwiftUI

/// A small floating panel that turns sound into text as it is heard: the
/// Mac's own sound — a video, a call — or the microphone.
@MainActor
enum ListeningPanel {
    private static var panel: NSPanel?
    private static var model: ListeningModel?

    static let shortcut = "⌥⇧⌘2"

    /// Opens the panel and starts listening, or closes it.
    static func toggle() {
        if panel != nil { close() } else { open() }
    }

    static func open() {
        guard panel == nil else { return }
        let model = ListeningModel()
        let size = NSSize(width: 380, height: 300)
        // Near the top right of the screen the pointer is on, out of the way
        // of whatever is playing.
        let at = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20)

        let panel = Panel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.nonactivatingPanel, .borderless, .resizable],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 200)
        panel.contentView = NSHostingView(rootView: ListeningView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model
        model.start()
    }

    static func close() {
        model?.stop()
        model = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

// MARK: - Model

@MainActor
private final class ListeningModel: ObservableObject {
    @Published var settled = ""
    @Published var hearing = ""
    @Published private(set) var listening = false
    @Published private(set) var starting = false
    @Published var error: String?
    @Published private(set) var source: Listening.Source
    @Published private(set) var locale: Locale
    @Published private(set) var locales: [Locale] = []

    private var listener: Listening?
    private static let sourceKey = "listening.source"
    private static let localeKey = "listening.locale"

    init() {
        let defaults = UserDefaults.standard
        source = defaults.string(forKey: Self.sourceKey).flatMap(Listening.Source.init(rawValue:)) ?? .mac
        locale = Locale(identifier: defaults.string(forKey: Self.localeKey) ?? "ru_RU")
        Task {
            let all = await DictationTranscriber.supportedLocales
            locales = all.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        }
    }

    var text: String {
        [settled, hearing].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func start() {
        guard !listening, !starting else { return }
        error = nil
        starting = true
        let listener = Listening()
        listener.onText = { [weak self] settled, hearing in
            guard let self else { return }
            // What came before this listening stays above it.
            self.settled = Self.join(self.carried, settled)
            self.hearing = hearing
        }
        listener.onFailure = { [weak self] error in
            self?.error = error.localizedDescription
            self?.stop()
        }
        self.listener = listener
        carried = settled
        let source = source, locale = locale
        Task {
            do {
                try await listener.start(source: source, locale: locale)
                listening = true
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.listener = nil
            }
            starting = false
        }
    }

    /// The text from earlier listenings, kept when listening starts again.
    private var carried = ""

    func stop() {
        guard let listener else { return }
        self.listener = nil
        listening = false
        Task {
            await listener.stop()
            if !hearing.isEmpty {
                settled = Self.join(settled, hearing)
                hearing = ""
            }
        }
    }

    func choose(source: Listening.Source) {
        guard source != self.source else { return }
        self.source = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        restart()
    }

    func choose(locale: Locale) {
        self.locale = locale
        UserDefaults.standard.set(locale.identifier, forKey: Self.localeKey)
        restart()
    }

    func clear() {
        settled = ""
        hearing = ""
        carried = ""
        restart()
    }

    private func restart() {
        let wasListening = listening || starting
        guard wasListening, let listener else { return }
        self.listener = nil
        listening = false
        Task {
            await listener.stop()
            if !hearing.isEmpty { settled = Self.join(settled, hearing); hearing = "" }
            start()
        }
    }

    /// "Russian" rather than "Russian (Russia)", for the button.
    func shortName(of locale: Locale) -> String {
        locale.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
            ?? name(of: locale)
    }

    func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

// MARK: - View

private struct ListeningView: View {
    @ObservedObject var model: ListeningModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            tabs
            Spacer()
            languageMenu
            Button {
                ListeningPanel.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Grey like the translation popover's tabs.
    private var tabs: some View {
        HStack(spacing: 0) {
            tab("Mac Audio", "speaker.wave.2", .mac)
            tab("Microphone", "mic", .microphone)
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func tab(_ title: String, _ symbol: String, _ source: Listening.Source) -> some View {
        let chosen = model.source == source
        return Button {
            model.choose(source: source)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: chosen ? .medium : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(chosen ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.gray.opacity(0.32))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(model.locales, id: \.identifier) { locale in
                Button {
                    model.choose(locale: locale)
                } label: {
                    if locale.identifier == model.locale.identifier {
                        Label(model.name(of: locale), systemImage: "checkmark")
                    } else {
                        Text(model.name(of: locale))
                    }
                }
            }
        } label: {
            Text(model.shortName(of: model.locale)).font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Language of the speech")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.settled.isEmpty && model.hearing.isEmpty {
                        placeholder
                    } else {
                        (Text(model.settled) + Text(model.settled.isEmpty ? "" : " ")
                            + Text(model.hearing).foregroundColor(.secondary))
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: model.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.starting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting ready…").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        } else if model.listening {
            Text(model.source == .mac ? "Listening to the Mac’s sound…" : "Listening to the microphone…")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        } else {
            Text("Press Listen to start.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.listening || model.starting ? model.stop() : model.start()
            } label: {
                Label(model.listening || model.starting ? "Stop" : "Listen",
                      systemImage: model.listening || model.starting ? "stop.fill" : "record.circle")
            }
            if model.listening {
                Circle().fill(.red).frame(width: 7, height: 7).help("Listening")
            }
            Spacer()
            Button("Clear") { model.clear() }
                .disabled(model.text.isEmpty)
            Button("Translate") { Translator.show(model.text) }
                .disabled(model.text.isEmpty)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .disabled(model.text.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

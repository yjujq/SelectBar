import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// Translation by macOS itself — the engine behind Safari's and Notes'
/// Translate — shown in a popover of SelectBar's own by the pointer.
///
/// The system's ready-made popover would do, but it takes no languages from
/// the caller and keeps none of the ones picked in it. So the translation is
/// asked of a translation session and laid out here, with both languages
/// chosen in the popover and remembered for the next time.
@MainActor
enum SystemTranslation {
    private static var host: NSPanel?
    private static var popover: NSPopover?
    private static var monitors: [Any] = []

    static func show(_ text: String) {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        close()
        Translator.close()

        let at = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let arrowAndMargin: CGFloat = 6 + 14 + 10
        let above = visible.maxY - at.y - arrowAndMargin
        let below = at.y - visible.minY - arrowAndMargin
        // Above, as the bar was, unless that leaves too little and below is roomier.
        let up = above >= 280 || above >= below

        let panel = HostPanel(contentRect: NSRect(x: at.x, y: up ? at.y + 6 : at.y - 6, width: 1, height: 1),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        panel.contentView = anchor
        // Key without activating: the app in front stays in front.
        panel.makeKeyAndOrderFront(nil)
        host = panel

        let model = MacTranslationModel(original: original, room: up ? above : below)
        let controller = NSHostingController(rootView: MacTranslationView(model: model))
        controller.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: up ? .maxY : .minY)
        self.popover = popover

        watchForDismissal()
        model.start()
    }

    static func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        popover?.close()
        popover = nil
        host?.orderOut(nil)
        host = nil
    }

    /// Clicks elsewhere land in other apps, out of the popover's sight.
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

// MARK: - Model

@MainActor
private final class MacTranslationModel: ObservableObject {
    let original: String
    let room: CGFloat

    /// nil: detected from the text.
    @Published private(set) var source: Locale.Language?
    @Published private(set) var target: Locale.Language
    @Published private(set) var languages: [Locale.Language] = []
    @Published private(set) var result: String?
    @Published private(set) var detected: Locale.Language?
    @Published private(set) var error: String?
    /// A new value asks the system for a new translation.
    @Published var configuration: TranslationSession.Configuration?

    private static let sourceKey = "macTranslate.source"
    private static let targetKey = "macTranslate.target"

    init(original: String, room: CGFloat) {
        self.original = original
        self.room = room
        let defaults = UserDefaults.standard
        source = defaults.string(forKey: Self.sourceKey).map(Locale.Language.init(identifier:))
        target = Locale.Language(identifier: defaults.string(forKey: Self.targetKey)
                                 ?? Translator.targetLanguage(for: original))
    }

    func start() {
        translate()
        Task {
            let all = await LanguageAvailability().supportedLanguages
            var seen = Set<String>()
            languages = all
                .filter { seen.insert($0.minimalIdentifier).inserted }
                .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        }
    }

    func chooseSource(_ language: Locale.Language?) {
        source = language
        UserDefaults.standard.set(language?.minimalIdentifier, forKey: Self.sourceKey)
        translate()
    }

    func chooseTarget(_ language: Locale.Language) {
        target = language
        UserDefaults.standard.set(language.minimalIdentifier, forKey: Self.targetKey)
        translate()
    }

    /// Detection would find the text already in the chosen language — a
    /// Russian text with Russian picked — and there is nothing to translate
    /// it into. Then it goes the usual other way: into English, or out of it.
    var effectiveTarget: Locale.Language {
        let from = source ?? recognised
        if let from, from.languageCode == target.languageCode {
            return Locale.Language(identifier: from.languageCode == .english ? "ru" : "en")
        }
        return target
    }

    private var recognised: Locale.Language? {
        NLLanguageRecognizer.dominantLanguage(for: original).map { Locale.Language(identifier: $0.rawValue) }
    }

    private func translate() {
        result = nil
        error = nil
        detected = nil
        let next = TranslationSession.Configuration(source: source, target: effectiveTarget)
        if configuration == next { configuration?.invalidate() } else { configuration = next }
    }

    func run(_ session: TranslationSession) async {
        do {
            let response = try await session.translate(original)
            result = response.targetText
            detected = response.sourceLanguage
        } catch {
            self.error = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return "macOS cannot translate between these languages."
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return "Could not tell what language this is. Choose it under From."
        }
        return error.localizedDescription
    }

    func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}

// MARK: - View

/// Laid out as SelectBar's DeepL popover: the original under its language,
/// the translation under its, and the button; each language a menu.
private struct MacTranslationView: View {
    @ObservedObject var model: MacTranslationModel
    @State private var copied: String?
    private let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section {
                sourceMenu
            } content: {
                Text(model.original)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            section {
                targetMenu
            } content: {
                if let result = model.result {
                    translation(result)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Translating…").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .translationTask(model.configuration) { session in
            await model.run(session)
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                model.chooseSource(nil)
            } label: {
                if model.source == nil { Label("Detect Language", systemImage: "checkmark") } else { Text("Detect Language") }
            }
            if !model.languages.isEmpty { Divider() }
            ForEach(model.languages, id: \.minimalIdentifier) { language in
                Button {
                    model.chooseSource(language)
                } label: {
                    if model.source?.minimalIdentifier == language.minimalIdentifier {
                        Label(model.name(of: language), systemImage: "checkmark")
                    } else {
                        Text(model.name(of: language))
                    }
                }
            }
        } label: {
            Text(sourceTitle).font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Translate from")
    }

    private var targetMenu: some View {
        Menu {
            ForEach(model.languages, id: \.minimalIdentifier) { language in
                Button {
                    model.chooseTarget(language)
                } label: {
                    if model.target.minimalIdentifier == language.minimalIdentifier {
                        Label(model.name(of: language), systemImage: "checkmark")
                    } else {
                        Text(model.name(of: language))
                    }
                }
            }
        } label: {
            Text(model.name(of: model.effectiveTarget)).font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Translate into")
    }

    /// "English", or "English (detected)" while it is detected.
    private var sourceTitle: String {
        if let source = model.source { return model.name(of: source) }
        if let detected = model.detected { return model.name(of: detected) + " (detected)" }
        return "Detect Language"
    }

    @ViewBuilder
    private func translation(_ text: String) -> some View {
        let body = Text(text)
            .font(.system(size: 16))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        let limit = max(80, min(300, model.room - 190))
        let estimate = CGFloat(text.count / 35 + 1 + text.filter(\.isNewline).count) * 22
        if estimate > limit {
            ScrollView { body }.frame(height: limit)
        } else {
            body
        }
    }

    private var footer: some View {
        HStack {
            Text("macOS")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(copied == model.result && copied != nil ? "Copied" : "Copy Translation") {
                guard let text = model.result else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .disabled(model.result == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
}

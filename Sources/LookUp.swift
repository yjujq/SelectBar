import AppKit

/// The panel macOS shows when you tap a word with three fingers.
///
/// Not the Dictionary application, and not the "Look Up in Dictionary"
/// service, both of which open a window somewhere else. This is the small
/// panel that appears over the word itself, with the dictionary entry, the
/// thesaurus, Siri knowledge, Wikipedia and whatever else the system has to
/// say — `LookupViewService`, which AppKit reaches through
/// `showDefinition(for:at:)`.
///
/// The catch is that the panel is drawn into the window of whoever asks for
/// it. There is no way to make another application's window show it, so this
/// one hosts it: a window a single point across, put where the pointer is —
/// which is where the bar is, which is where the word is — and the panel
/// hangs off that.
///
/// Sending the keystroke instead was the other way, and worse. Control-
/// Command-D is what the system binds Look Up to, and in Safari, Mail or
/// TextEdit it opens this very panel at the very word. In Chrome, in
/// Electron, in anything that does not carry AppKit's text view, it does
/// nothing at all and says nothing about it.
enum LookUp {
    /// Held for as long as the panel is up: it belongs to this window, and
    /// closing the window takes it with it.
    private static var host: NSWindow?
    private static var dismissal: (any NSObjectProtocol)?

    static func show(_ text: String) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        close()

        let at = NSEvent.mouseLocation
        let window = Host(contentRect: NSRect(x: at.x, y: at.y, width: 1, height: 1),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView = anchor
        window.makeKeyAndOrderFront(nil)
        host = window

        // The panel will not open for a window that cannot take the keyboard,
        // and a window cannot take it while its application is behind
        // everybody else. So this one comes forward — and goes away again the
        // moment anything else is clicked, which is also when the panel goes.
        NSApp.activate()
        anchor.showDefinition(for: NSAttributedString(string: word),
                              at: NSPoint(x: 0, y: 0))

        dismissal = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    private static func close() {
        if let dismissal {
            NotificationCenter.default.removeObserver(dismissal)
            self.dismissal = nil
        }
        host?.orderOut(nil)
        host = nil
    }

    /// Borderless windows are never key, and without the keyboard there is no
    /// panel.
    private final class Host: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

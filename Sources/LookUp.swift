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
                          styleMask: [.nonactivatingPanel, .borderless],
                          backing: .buffered, defer: false)
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
        // and this is the only way to take it here.
        //
        // Coming forward was the obvious way and it does not work. The bar is
        // a non-activating panel that never becomes key, so clicking it never
        // makes this application active; and since macOS 14 an application
        // that is not active, and that nobody has interacted with, is refused
        // when it asks to become so. Traced inside the running app: twenty
        // attempts over four hundred milliseconds, active false and key false
        // throughout, and a panel told to open for a window that was not key
        // opens into nothing at all — which is exactly what a button that
        // does nothing looks like.
        //
        // A non-activating panel takes key status without its application
        // going anywhere, which is what the bar itself is built from. The
        // application in front stays in front and stays frontmost.
        wait(for: window) {
            anchor.showDefinition(for: NSAttributedString(string: word),
                                  at: NSPoint(x: 0, y: 0))
            // Only now is the click that dismisses it worth watching for.
            // Coming forward is itself a resignation or two — the bar closing
            // hands focus back for a moment — and watching through that shut
            // the panel before anyone saw it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { watchForDismissal() }
        }
    }

    /// Runs the block once the window has the keyboard, or gives up.
    ///
    /// Polled rather than waited on a notification: `didBecomeActive` arrives
    /// before the window has actually been made key, which is the state that
    /// matters here.
    private static func wait(for window: NSWindow, attempt: Int = 0,
                             then act: @escaping () -> Void) {
        window.makeKeyAndOrderFront(nil)
        if window.isKeyWindow || attempt >= 20 {
            act()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { wait(for: window, attempt: attempt + 1, then: act) }
        }
    }

    private static func watchForDismissal() {
        guard host != nil, dismissal == nil else { return }
        dismissal = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                close()
            }
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
    /// panel. A panel says so for itself.
    private final class Host: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

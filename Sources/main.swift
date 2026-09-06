import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let reader = SelectionReader()
    private let popup = PopupController()
    private var statusItem: NSStatusItem!
    private let settingsWindow = SettingsWindowController()
    private let menuPanel = FloatingPanel()
    private let settingsPanel = FloatingPanel()
    private let store = ActionStore.shared
    private var mouseMonitor: Any?
    private let notifications = NotificationWatcher()
    private var pendingWork: DispatchWorkItem?
    private var mouseDownPoint: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyStatusIconVisibility()
        NotificationCenter.default.addObserver(
            forName: .statusIconVisibilityChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.applyStatusIconVisibility() }
        }

        guard AX.trusted(prompt: true) else {
            // Permission is not granted instantly — wait for it in the background.
            waitForAccessibility()
            return
        }
        startWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatching()
    }

    /// Relaunching from Finder is the only way back to settings when the icon
    /// is hidden, so open them.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    // MARK: - Menu bar

    private func applyStatusIconVisibility() {
        if store.showStatusIcon {
            if statusItem == nil { setUpStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder",
                                           accessibilityDescription: "SelectBar")

        // The menu is not assigned to statusItem: that would swallow every
        // click and settings would never open. We handle the click ourselves.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])


    }

    /// Left click shows settings under the icon, right click the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        menuPanel.hide()
        guard let button = statusItem?.button else { return }
        if settingsPanel.isShown {
            settingsPanel.hide()
        } else {
            // takesFocus: settings hold text fields and pickers, which take no
            // input at all in a panel that never becomes key.
            settingsPanel.show(SettingsView(store: .shared).panelChrome(),
                               below: button, takesFocus: true)
        }
    }

    /// The menu is shown once: assign, click, remove immediately — otherwise
    /// it would stay attached to the left click too.
    private func showMenu() {
        guard let button = statusItem?.button else { return }
        settingsPanel.hide()
        menuPanel.show(
            MenuPanelView(entries: menuEntries()) { [weak self] in self?.menuPanel.hide() },
            below: button
        )
    }

    private func menuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = [
            MenuEntry(title: "Restart", symbol: "arrow.clockwise", shortcut: "⌘R") {
                [weak self] in self?.restartApp()
            }
        ]

        // While access is not granted, show the way to the settings. Once it
        // is, the row disappears: no point reminding about what is done.
        if !AX.trusted(prompt: false) {
            entries.append(
                MenuEntry(title: "Accessibility Settings…", symbol: "lock.shield") {
                    [weak self] in self?.openAccessibilitySettings()
                }
            )
        }

        entries.append(
            MenuEntry(title: "Quit", symbol: "power", shortcut: "⌘Q", isDestructive: true) {
                NSApp.terminate(nil)
            }
        )
        return entries
    }

    /// Restart: launch a new instance after a delay, then quit this one.
    /// The delay keeps `open` from running into the still-live process.
    @objc private func restartApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Waiting for permission

    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            // The check and the invalidation happen here: Swift 6 forbids
            // passing the timer itself into an isolated closure.
            guard AX.trusted(prompt: false) else { return }
            timer.invalidate()
            MainActor.assumeIsolated { [weak self] in
                self?.startWatching()
            }
        }
    }

    // MARK: - Watching the selection

    private func startWatching() {
        // Mouse-down is tracked alongside mouse-up: the distance between them
        // shows whether the mouse was dragged or clicked in place, which
        // decides the delay.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { event in
            // The numbers are taken here: the event object itself cannot be
            // passed into an isolated closure.
            let isDown = event.type == .leftMouseDown
            let clicks = event.clickCount
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { [weak self] in
                if isDown {
                    self?.mouseDownPoint = point
                } else {
                    self?.handleMouseUp(at: point, clickCount: clicks)
                }
            }
        }

        notifications.onBanner = { [weak self] in
            guard let self, self.store.blinkOnNotification else { return }
            Task { await Lights.blink(duration: .seconds(3), interval: .milliseconds(400)) }
        }
        notifications.start()
    }

    private func stopWatching() {
        notifications.stop()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func handleMouseUp(at point: NSPoint, clickCount: Int) {
        popup.hide()

        // The selection does not settle the instant the button is released.
        pendingWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            // A single click in a field just places the caret, and the paste
            // bar has no business appearing for it. A double click is needed.
            self.reader.offerPaste = self.store.offerPaste && clickCount >= 2
            guard let context = self.reader.read() else { return }
            switch context {
            case .selection(let selection, let editable):
                self.popup.show(actions: self.store.actions(forSelectedText: selection.text,
                                                            editable: editable),
                                text: selection.text,
                                rect: selection.rect,
                                near: point)
            case .editableField(let caret):
                self.popup.show(actions: self.store.actionsForEmptyField(),
                                text: "", rect: caret, near: point)
            }
            }
        }
        pendingWork = work

        // A click in place may turn out to be the first of a double, and then
        // a second release follows. We wait long enough to cancel the showing:
        // otherwise the bar appeared twice — once on the first click and again
        // on the second.
        //
        // A drag selection needs no wait: no double click follows one, and the
        // extra delay would be noticeable on every selection.
        let dragged = mouseDownPoint.map { down in
            abs(down.x - point.x) + abs(down.y - point.y) > 4
        } ?? false
        // 0.3 instead of the system interval: that defaults to half a second,
        // while the second click actually arrives noticeably sooner. Waiting
        // the full interval was too obvious on every double click.
        let delay = dragged ? 0.12 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

let app = NSApplication.shared

// The delegate must live in a global: NSApplication holds it weakly, and
// inside a closure it would be released immediately.
let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon
    app.run()
}

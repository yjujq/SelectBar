import AppKit

/// SelectBar — панель действий над выделенным текстом.
/// Фоновый агент без иконки в доке, живёт в строке меню.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let reader = SelectionReader()
    private let popup = PopupController()
    private var statusItem: NSStatusItem!
    private let settingsWindow = SettingsWindowController()
    private let store = ActionStore.shared
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private let notifications = NotificationWatcher()
    private var pendingWork: DispatchWorkItem?
    private var enabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyStatusIconVisibility()
        NotificationCenter.default.addObserver(
            forName: .statusIconVisibilityChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.applyStatusIconVisibility() }
        }

        guard AX.trusted(prompt: true) else {
            // Разрешение выдаётся не мгновенно — ждём его в фоне.
            waitForAccessibility()
            return
        }
        startWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatching()
    }

    /// Повторный запуск из Finder — единственный способ вернуться к настройкам,
    /// когда значок скрыт. Поэтому открываем их.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    // MARK: - Строка меню

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
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let toggle = NSMenuItem(title: enabled ? "Pause" : "Resume",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let blink = NSMenuItem(title: "Blink keyboard",
                               action: #selector(blinkLights), keyEquivalent: "")
        blink.target = self
        blink.isEnabled = Lights.available
        menu.addItem(blink)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)


        menu.addItem(.separator())

        // Пока доступ не выдан — показываем путь к настройкам. После выдачи
        // пункт исчезает: напоминать об уже сделанном незачем.
        if !AX.trusted(prompt: false) {
            let access = NSMenuItem(title: "Open Accessibility Settings…",
                                    action: #selector(openAccessibilitySettings), keyEquivalent: "")
            access.target = self
            menu.addItem(access)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if !enabled { popup.hide() }
        rebuildMenu()
    }

    @objc private func blinkLights() {
        Task { await Lights.blink() }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Ожидание разрешения

    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            // Проверку и остановку таймера делаем здесь: передавать сам таймер
            // внутрь изолированного замыкания Swift 6 запрещает.
            guard AX.trusted(prompt: false) else { return }
            timer.invalidate()
            MainActor.assumeIsolated { [weak self] in
                self?.rebuildMenu()
                self?.startWatching()
            }
        }
    }

    // MARK: - Слежение за выделением

    private func startWatching() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { event in
            // Числа снимаем здесь: сам объект события передавать внутрь
            // изолированного замыкания нельзя.
            let clicks = event.clickCount
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { [weak self] in
                self?.handleMouseUp(at: point, clickCount: clicks)
            }
        }

        // Пробел как спусковой крючок. Монитор только наблюдает и событие
        // не съедает, поэтому пробел печатается как обычно.
        if store.blinkOnSpace { InputMonitoring.request() }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            let code = event.keyCode
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.enabled, self.store.blinkOnSpace, code == 49 else { return }
                Task { await Lights.blink(duration: .seconds(3), interval: .milliseconds(400)) }
            }
        }

        notifications.onBanner = { [weak self] in
            guard let self, self.enabled, self.store.blinkOnNotification else { return }
            Task { await Lights.blink(duration: .seconds(3), interval: .milliseconds(400)) }
        }
        notifications.start()
    }

    private func stopWatching() {
        notifications.stop()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func handleMouseUp(at point: NSPoint, clickCount: Int) {
        guard enabled else { return }
        popup.hide()

        // Выделение устаканивается не мгновенно после отпускания кнопки.
        pendingWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            // Одиночный щелчок в поле — это просто установка курсора, и панель
            // вставки на него лезть не должна. Нужен двойной.
            self.reader.offerPaste = self.store.offerPaste && clickCount >= 2
            guard let context = self.reader.read() else { return }
            switch context {
            case .selection(let selection):
                self.popup.show(actions: self.store.actions(forSelectedText: selection.text),
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

let app = NSApplication.shared

// Делегат обязан жить в глобальной переменной: NSApplication держит его
// слабой ссылкой, и внутри замыкания он был бы сразу освобождён.
let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // без иконки в доке
    app.run()
}

import AppKit

/// Панель, которая никогда не забирает фокус.
///
/// Это ключевое требование: если окно станет ключевым, приложение под ним
/// снимет выделение, и мы покажем кнопки для текста, которого уже нет.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupController {
    private var panel: NonActivatingPanel?
    private var currentText = ""
    private var currentActions: [Action] = []
    private var dismissMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(actions: [Action], text: String, rect: NSRect?, near fallbackPoint: NSPoint) {
        hide()
        guard !actions.isEmpty else { return }
        currentText = text
        currentActions = actions

        let content = buildBar(actions: actions)
        let size = content.fittingSize

        let origin = position(rect: rect, size: size, fallback: fallbackPoint)
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = appearance(for: ActionStore.shared.barAppearance)
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel

        // Закрываемся от любого клика или нажатия клавиши вне панели.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.hide() }
        }
    }

    func hide() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Построение панели

    private func buildBar(actions: [Action]) -> NSView {
        let store = ActionStore.shared
        let scale = store.barScale

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 4 * scale, left: 6 * scale,
                                        bottom: 4 * scale, right: 6 * scale)
        for action in actions {
            stack.addArrangedSubview(makeButton(for: action))
        }

        let size = stack.fittingSize
        let radius: CGFloat = 11 * scale

        let container = makeBackground(store: store, size: size, radius: radius, stack: stack)
        // Тему ставим на саму подложку, а не только на окно: иначе цвета иконок
        // берутся из системной темы и на своей заливке читаются неверно.
        container.appearance = appearance(for: store.barAppearance)
        return container
    }

    private func appearance(for setting: BarAppearance) -> NSAppearance? {
        switch setting {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Сплошной цвет подложки: тёмный или светлый, с наложенным оттенком.
    /// В отличие от стекла не зависит от того, что находится под панелью.
    private func solidColor(store: ActionStore) -> NSColor {
        let dark: Bool
        switch store.barAppearance {
        case .light: dark = false
        case .dark:  dark = true
        case .system:
            dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        var base = dark ? NSColor(white: 0.14, alpha: 0.97)
                        : NSColor(white: 0.97, alpha: 0.97)

        // Оттенок подмешиваем в основу, а не кладём сверху отдельным слоем.
        if let tint = store.tintColor?.usingColorSpace(.sRGB),
           let mixed = base.usingColorSpace(.sRGB) {
            let a = tint.alphaComponent
            base = NSColor(srgbRed: mixed.redComponent * (1 - a) + tint.redComponent * a,
                           green: mixed.greenComponent * (1 - a) + tint.greenComponent * a,
                           blue: mixed.blueComponent * (1 - a) + tint.blueComponent * a,
                           alpha: mixed.alphaComponent)
        }
        return base
    }

    private func makeBackground(store: ActionStore, size: NSSize,
                                radius: CGFloat, stack: NSStackView) -> NSView {
        func fill(_ view: NSView) -> NSView {
            view.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stack.topAnchor.constraint(equalTo: view.topAnchor),
                stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            view.frame = NSRect(origin: .zero, size: size)
            return view
        }

        if #available(macOS 26.0, *), store.barStyle == .glass || store.barStyle == .glassClear {
            let glass = NSGlassEffectView()
            glass.style = store.barStyle == .glassClear ? .clear : .regular
            glass.tintColor = store.tintColor
            glass.cornerRadius = radius
            stack.translatesAutoresizingMaskIntoConstraints = true
            stack.frame = NSRect(origin: .zero, size: size)
            glass.contentView = stack
            glass.frame = NSRect(origin: .zero, size: size)
            return glass
        }

        if store.barStyle == .blur {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            return fill(blur)
        }

        let plain = NSView()
        plain.wantsLayer = true
        plain.layer?.cornerRadius = radius
        plain.layer?.masksToBounds = true
        plain.layer?.backgroundColor = solidColor(store: store).cgColor
        return fill(plain)
    }

    private func makeButton(for action: Action) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(perform(_:)))

        // Часть символов появилась в свежих версиях SF Symbols — если имени нет,
        // берём запасное, чтобы кнопка не осталась пустой.
        let scale = ActionStore.shared.barScale
        let config = NSImage.SymbolConfiguration(pointSize: 14 * scale, weight: .regular)
        let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            ?? NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: action.title)
        if let image {
            button.image = image.withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
        } else {
            button.title = action.title       // совсем без картинки — пусть будет подпись
        }

        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.setButtonType(.momentaryChange)
        button.toolTip = action.tooltip ?? action.title
        button.identifier = NSUserInterfaceItemIdentifier(action.title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28 * scale),
            button.heightAnchor.constraint(equalToConstant: 22 * scale),
        ])
        return button
    }

    @objc private func perform(_ sender: NSButton) {
        let title = sender.identifier?.rawValue ?? ""
        let text = currentText
        hide()
        currentActions.first { $0.title == title }?.run(text)
    }

    // MARK: - Размещение

    private func position(rect selectionRect: NSRect?, size: NSSize, fallback: NSPoint) -> NSPoint {
        let gap: CGFloat = 8
        var origin: NSPoint
        if let rect = selectionRect, rect.width > 0 || rect.height > 0 {
            // Над выделением, по центру.
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
        } else {
            origin = NSPoint(x: fallback.x - size.width / 2, y: fallback.y + gap * 2)
        }

        // Не вылезать за пределы экрана, на котором находимся.
        let screen = NSScreen.screens.first { $0.frame.contains(origin) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        if origin.y + size.height > visible.maxY {
            // Сверху не помещается — показываем под выделением.
            let rectMinY = selectionRect?.minY ?? fallback.y
            origin.y = rectMinY - size.height - gap
        }
        origin.y = max(origin.y, visible.minY + 4)
        return origin
    }
}

import AppKit
import ObjectiveC.runtime

/// A panel that never takes focus.
///
/// This is essential: if the window became key, the application beneath would
/// drop the selection and we would show buttons for text that no longer exists.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel's backing view, which declares the arrow cursor itself.
///
/// Without this the cursor over the panel stays the one from the window below
/// — usually the I-beam of the text field the selection came from. It misleads:
/// the pointer looks as if it were over text when it is really over a button.
private final class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
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

        let origin = position(size: size, cursor: fallbackPoint)
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Level 3: above ordinary app windows (0) but below the Dock (20), the
        // menu bar (24), Control Centre (25) and context menus (~101). At
        // popUpMenu the panel covered all of those, tooltips included.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Only the solid fill needs a shadow. Glass casts its own, and a
        // second one lays a double outline over it; with blur the window shadow
        // rims the capsule visibly — the backing view draws nothing itself,
        // borderWidth is 0 throughout its layer tree.
        panel.hasShadow = ActionStore.shared.barStyle == .solid
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = appearance(for: ActionStore.shared.barAppearance)
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel

        // Dismiss on any click or key press outside the panel.
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

    // MARK: - Building the bar

    private func buildBar(actions: [Action]) -> NSView {
        let store = ActionStore.shared
        let scale = store.barScale

        if #available(macOS 26.0, *),
           store.barStyle == .glass || store.barStyle == .glassClear {
            return buildGlassBar(actions: actions, store: store, scale: scale)
        }

        // Buttons sit flush against each other and fill the capsule's height:
        // no dead strips remain between them, so the icon cannot be missed.
        // The capsule keeps its size — what the buttons gained came from the
        // insets.
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2.5 * scale,
                                        bottom: 0, right: 2.5 * scale)
        for action in actions {
            stack.addArrangedSubview(makeButton(for: action,
                                                width: 31 * scale, height: 30 * scale))
        }

        let size = stack.fittingSize
        // Half the height makes a capsule: the ends are fully rounded into
        // semicircles. Measured from the actual size so the shape holds at any
        // bar scale.
        let radius: CGFloat = size.height / 2

        let container = makeBackground(store: store, size: size, radius: radius, stack: stack)
        // The appearance is set on the backing view, not only on the window:
        // otherwise the icon colours come from the system theme and read wrong
        // against our own fill.
        container.appearance = appearance(for: store.barAppearance)
        return container
    }

    /// A glass bar the way Apple builds them: one capsule in a container.
    ///
    /// NSGlassEffectContainerView is still the host even for a single shape —
    /// it is where a glass view belongs, and it is what draws the shadow and
    /// glow around it. Stacking glass on glass by hand is not allowed: the
    /// layers start refracting each other and the look falls apart.
    ///
    /// The buttons deliberately sit NOT inside the glass but as a separate
    /// layer above it. Inside the glass, clicks never reached them. Off screen
    /// the layout passes every check, so it is the live glass layer that
    /// intercepts them, and its behaviour is beyond our control. The glass is
    /// therefore left as a pure backdrop: clicks travel through ordinary views
    /// and do not depend on it.
    @available(macOS 26.0, *)
    private func buildGlassBar(actions: [Action], store: ActionStore, scale: CGFloat) -> NSView {
        // One capsule holding every action, in the order they are configured.
        // The bar used to be split by meaning — built-ins, links, shell
        // commands — into a capsule apiece with a gap between them, left to
        // the container to fuse. Adding an action of a new kind then grew the
        // bar by a separate piece instead of lengthening the one shape, and
        // the split also reshuffled the icons out of their configured order.
        //
        // Apple's insets for an icon bar: noticeably wider at the sides than
        // at the top.
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 0
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 2.5 * scale,
                                          bottom: 0, right: 2.5 * scale)
        for action in actions {
            buttons.addArrangedSubview(makeButton(for: action,
                                                  width: 33 * scale, height: 32 * scale))
        }
        // The button row also sets the size the glass is built from.
        let size = buttons.fittingSize

        // An almost transparent fill in the capsule's shape. The panel's
        // window is transparent, and macOS passes a click through to the
        // window below wherever the pixel in the window's buffer is empty.
        // Glass is drawn by a separate compositor layer and writes nothing
        // into that buffer, so without this fill the only opaque pixels are
        // the icon strokes themselves: hit a stroke and it worked, hit a gap
        // and it went into the text below. Hence the I-beam instead of an
        // arrow, and clicks that worked only half the time.
        //
        // Blur does not need this: NSVisualEffectView fills the area itself,
        // which is why nothing of the sort showed up in Blur.
        buttons.wantsLayer = true
        buttons.layer?.backgroundColor = NSColor(white: 0, alpha: 0.02).cgColor
        buttons.layer?.cornerRadius = size.height / 2

        // A glass backdrop of the same size, but empty inside.
        let capsule = NSGlassEffectView()
        // .clear only over stills and video; .regular for everything else,
        // or the icons lose their footing and stop reading against a busy
        // background.
        capsule.style = store.barStyle == .glassClear ? .clear : .regular
        capsule.tintColor = store.tintColor
        capsule.cornerRadius = size.height / 2

        // Glass adapts its appearance to whatever is beneath it: lighter
        // over a light background, darker over a dark one. We want the
        // appearance from settings, not from the wallpaper, so the
        // adaptation is turned off.
        //
        // The property is internal: 0 is automatic, 1 off, 2 on (the
        // default). The values were found by trying them; 3 crashes AppKit,
        // so only 1 is used. Its presence is checked: were it to vanish in
        // a future release, setValue would raise an Objective-C exception
        // that Swift cannot catch and the panel would crash on every show.
        // This way it simply keeps adapting — worse looking, still working.
        //
        // Glass (clear) is the exception and is left to adapt. It is the style
        // meant to read like the Dock, and the Dock adapts: it lightens over a
        // light background and darkens over a dark one. Held to a fixed tone
        // the bar stops looking see-through and reads as a flat plate instead.
        // The cost is the very fault that turned adaptation off in the first
        // place — over a light background the glass goes pale, and light icons
        // on it lose their footing.
        if store.barStyle != .glassClear,
           class_getProperty(NSGlassEffectView.self, "_adaptiveAppearance") != nil {
            capsule.setValue(1, forKey: "_adaptiveAppearance")
        }
        capsule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            capsule.widthAnchor.constraint(equalToConstant: size.width),
            capsule.heightAnchor.constraint(equalToConstant: size.height),
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        row.addArrangedSubview(capsule)

        let container = NSGlassEffectContainerView()
        // Nothing left to fuse: the bar is a single capsule, so the container
        // keeps its default spacing.
        row.translatesAutoresizingMaskIntoConstraints = true
        row.frame = NSRect(origin: .zero, size: size)
        container.contentView = row
        container.frame = NSRect(origin: .zero, size: size)
        container.appearance = appearance(for: store.barAppearance)

        // The wrapper: glass below, buttons above. Their geometry matches
        // exactly because both are built from the same insets and gaps.
        // A margin around the edges. Glass draws its own shadow and glow
        // BEYOND the bounds of its view, while the panel's window is sized to
        // its content. Without the margin the visible capsule ends up larger
        // than the window: move the mouse towards its edge and you leave the
        // window before you leave the picture — the cursor becomes the I-beam
        // from the text below and the click goes there too, past the button.
        let margin: CGFloat = 0
        let outer = ArrowCursorView(frame: NSRect(x: 0, y: 0,
                                                  width: size.width + margin * 2,
                                                  height: size.height + margin * 2))
        container.translatesAutoresizingMaskIntoConstraints = true
        container.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        outer.addSubview(container)
        buttons.translatesAutoresizingMaskIntoConstraints = true
        buttons.frame = container.frame
        outer.addSubview(buttons)

        // Explicit sizes: otherwise fittingSize of an empty wrapper is zero
        // and the panel's window collapses.
        outer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outer.widthAnchor.constraint(equalToConstant: size.width + margin * 2),
            outer.heightAnchor.constraint(equalToConstant: size.height + margin * 2),
        ])
        outer.appearance = appearance(for: store.barAppearance)
        return outer
    }

    private func appearance(for setting: BarAppearance) -> NSAppearance? {
        switch setting {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// A solid background colour, dark or light, with the tint mixed in.
    /// Unlike glass it does not depend on what lies beneath the panel.
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

        // The tint is blended into the base rather than laid over it as a layer.
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

    /// The sizes come from the caller: a button must fill the capsule entirely
    /// so clicks register beyond the icon itself. The icon inside keeps its
    /// point size and simply sits centred — nothing changes to the eye.
    private func makeButton(for action: Action,
                            width: CGFloat, height: CGFloat) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(perform(_:)))

        // Some symbols only exist in recent SF Symbols releases — if the name
        // is unknown, fall back so the button is not left blank.
        let scale = ActionStore.shared.barScale
        let config = NSImage.SymbolConfiguration(pointSize: 14 * scale, weight: .regular)
        let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            ?? NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: action.title)
        // A missing symbol leaves nothing to show, so the title stands in
        // regardless of what the item asked for.
        let showsIcon = action.label.showsIcon && image != nil
        let showsText = action.label.showsText || !showsIcon

        if showsIcon, let image {
            button.image = image.withSymbolConfiguration(config)
        }
        if showsText {
            // Set as an attributed string rather than a plain title: the font
            // has to follow the bar's scale, and the colour has to be stated,
            // since contentTintColor reaches the icon but not the text.
            button.attributedTitle = NSAttributedString(
                string: action.title,
                attributes: [.font: NSFont.systemFont(ofSize: 12 * scale),
                             .foregroundColor: NSColor.labelColor])
        }
        button.imagePosition = showsIcon ? (showsText ? .imageLeading : .imageOnly) : .noImage

        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.setButtonType(.momentaryChange)
        button.toolTip = action.tooltip ?? action.title
        button.identifier = NSUserInterfaceItemIdentifier(action.title)
        button.translatesAutoresizingMaskIntoConstraints = false
        // A labelled button is as wide as its content; an icon-only one keeps
        // the width the caller asked for, so the bar's proportions hold when
        // nothing is labelled. Measured after the title and image are set, or
        // fittingSize would report the empty button.
        let finalWidth = showsText
            ? max(width, ceil(button.fittingSize.width) + 12 * scale)
            : width
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: finalWidth),
            button.heightAnchor.constraint(equalToConstant: height),
        ])
        return button
    }

    @objc private func perform(_ sender: NSButton) {
        let title = sender.identifier?.rawValue ?? ""
        let text = currentText
        hide()
        currentActions.first { $0.title == title }?.run(text)
    }

    // MARK: - Placement

    /// The bar is placed at the cursor rather than over the selection: that
    /// way it is always where the eye is and does not jump across the screen
    /// after a long selection whose start may be far from where the mouse was
    /// released.
    private func position(size: NSSize, cursor: NSPoint) -> NSPoint {
        let gap: CGFloat = 14
        var origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y + gap)

        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        // It does not fit above, so show it below the cursor.
        if origin.y + size.height > visible.maxY {
            origin.y = cursor.y - size.height - gap
        }
        origin.y = max(origin.y, visible.minY + 4)
        return origin
    }
}

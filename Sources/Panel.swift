import AppKit

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

    /// What was behind the bar the last time it was measured, for the Auto
    /// theme. Kept between showings: it is the starting guess for the next
    /// one, and a guess from a moment ago beats none at all.
    private var behindIsDark: Bool?

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
        panel.appearance = appearance(for: ActionStore.shared)
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel

        // Auto has to look at the screen, and looking is not instant. The bar
        // is drawn at once with the last reading — or the system's setting on
        // the very first showing — and put right a moment later if the reading
        // that comes back disagrees. Rebuilding is what a showing does anyway.
        if ActionStore.shared.barAppearance == .auto {
            let frame = NSRect(origin: origin, size: size)
            Task { [weak self] in
                guard let tone = await ScreenPhoto.tone(of: frame) else { return }
                guard let self, self.behindIsDark != tone else { return }
                self.behindIsDark = tone
                guard let panel = self.panel else { return }
                panel.appearance = self.appearance(for: ActionStore.shared)
                panel.contentView = self.buildBar(actions: actions)
            }
        }

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

    /// The bar as a loose view, for the preview in settings.
    ///
    /// It goes through the very code that builds the real thing rather than an
    /// imitation of it: a preview drawn a second way would drift from the bar
    /// the first time either is touched, and a preview that lies is worse than
    /// none.
    ///
    /// Its buttons still target this controller, and they are harmless. Their
    /// action looks the pressed title up in `currentActions`, which only `show`
    /// ever fills — a controller kept solely for previewing has none, so the
    /// lookup finds nothing and the press does nothing.
    func previewBar(actions: [Action]) -> NSView {
        buildBar(actions: actions)
    }

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
        // The side inset is carried by the outermost buttons rather than by
        // the stack — see endPadding. The bar comes out the same size either
        // way; the difference is that the hover highlight at either end now
        // reaches the capsule's own edge.
        for (index, action) in actions.enumerated() {
            stack.addArrangedSubview(
                makeButton(for: action,
                           width: 31 * scale + Self.endPadding(at: index,
                                                               of: actions.count,
                                                               inset: 2.5 * scale),
                           height: 30 * scale,
                           corners: Self.capsuleCorners(at: index, of: actions.count)))
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
        container.appearance = appearance(for: store)
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
        // The side inset is carried by the outermost buttons rather than by
        // the stack — see endPadding.
        for (index, action) in actions.enumerated() {
            buttons.addArrangedSubview(
                makeButton(for: action,
                           width: 33 * scale + Self.endPadding(at: index,
                                                               of: actions.count,
                                                               inset: 2.5 * scale),
                           height: 32 * scale,
                           corners: Self.capsuleCorners(at: index, of: actions.count)))
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
        // Always a capsule: the radius is half the height.
        let radius = size.height / 2
        buttons.wantsLayer = true
        buttons.layer?.backgroundColor = NSColor(white: 0, alpha: 0.02).cgColor
        buttons.layer?.cornerRadius = radius
        // Clipped to the capsule. The buttons come out taller than the bar —
        // measured at 45 to 49 points against its 38, each sized by its own
        // icon because the height constraint loses to the stack's fixed frame
        // — so they hang over the top and bottom edges. Nothing showed while
        // they were transparent, but the hover highlight is not, and without
        // this it spills outside the bar.
        buttons.layer?.masksToBounds = true

        // A glass backdrop of the same size, but empty inside.
        let capsule = NSGlassEffectView()
        // .clear only over stills and video; .regular for everything else,
        // or the icons lose their footing and stop reading against a busy
        // background.
        capsule.style = store.barStyle == .glassClear ? .clear : .regular
        capsule.tintColor = store.tintColor ?? automaticTint(store)
        capsule.cornerRadius = radius

        // No private write here any more. Setting _adaptiveAppearance also
        // moved _variant — measured: with the write both read 1, without it
        // both read 2 — so what looked like "hold the appearance still" was in
        // fact selecting a different glass variant, and the bar came out with
        // no glass in it at all. The appearance is left to the system.
        capsule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            capsule.widthAnchor.constraint(equalToConstant: size.width),
            capsule.heightAnchor.constraint(equalToConstant: size.height),
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        row.addArrangedSubview(capsule)

        let container = TunedGlassContainer()
        container.lens = store.barLens
        // No alphaValue here, however tempting. Glass is drawn by a separate
        // compositor layer that samples what lies behind the window, and any
        // alpha below 1 forces the view through an intermediate composite —
        // whereupon the system drops the effect altogether and the bar comes
        // out as a plain plate with no glass in it at all. The opacity setting
        // therefore reaches the solid and blur styles only; glass carries its
        // own translucency, chosen by its style.
        // Nothing left to fuse: the bar is a single capsule, so the container
        // keeps its default spacing.
        row.translatesAutoresizingMaskIntoConstraints = true
        row.frame = NSRect(origin: .zero, size: size)
        container.contentView = row
        container.frame = NSRect(origin: .zero, size: size)
        container.appearance = appearance(for: store)

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
        // The buttons stay OUTSIDE the glass, against Apple's documented
        // arrangement. Content belongs in a contentView and content inside
        // adapts along with the glass — which is exactly what these icons
        // fail to do. It was tried again once the bar became a single capsule,
        // on the chance that the old fault belonged to the old structure of a
        // capsule per group. It does not: inside the glass, clicks still never
        // reach the buttons. The live glass layer swallows them, and its
        // behaviour is beyond our reach.
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
        outer.appearance = appearance(for: store)

        return outer
    }

    private func appearance(for store: ActionStore) -> NSAppearance? {
        switch store.barAppearance {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        // Auto has to name one: leaving it to the system would be System.
        case .auto:   return NSAppearance(named: isDark(store) ? .darkAqua : .aqua)
        }
    }

    /// Whether the bar is drawing dark, by the setting, the system, or what it
    /// happens to be sitting on.
    private func isDark(_ store: ActionStore) -> Bool {
        switch store.barAppearance {
        case .light: return false
        case .dark:  return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .auto:
            // The same side as what is behind it: a dark bar over a dark page,
            // a light one over a light page. The bar then belongs to what it
            // is covering rather than standing against it, and its icons —
            // which take their colour from the theme — are light on the dark
            // one and dark on the light one, so they read either way. The
            // system's own setting stands in until the first measurement comes
            // back, and whenever the screen cannot be read at all.
            if let behindIsDark { return behindIsDark }
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// A tint that keeps the glass on the same side as its icons.
    ///
    /// Glass takes its tone from whatever lies behind the window, while the
    /// icons take theirs from the theme, and the two answer to different
    /// masters: over a white background the glass whitened, and white icons in
    /// dark mode disappeared into it entirely.
    ///
    /// Asking the glass what it had become is not possible — measured: its
    /// effectiveAppearance reads the same over a white background as over a
    /// black one, so the adaptation happens somewhere we cannot see. Instead
    /// the glass is leaned back towards the theme, faintly enough to stay
    /// glass. A tint the user set themselves wins over this.
    private func automaticTint(_ store: ActionStore) -> NSColor {
        isDark(store) ? NSColor(white: 0, alpha: 0.25)
                      : NSColor(white: 1, alpha: 0.25)
    }

    /// A solid background colour, dark or light, with the tint mixed in.
    /// Unlike glass it does not depend on what lies beneath the panel.
    private func solidColor(store: ActionStore) -> NSColor {
        let dark = isDark(store)
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
        // The backdrop and the buttons are siblings rather than nested, the
        // way the glass bar already builds them. Nested, the opacity setting
        // would fade the icons along with the background; apart, it reaches
        // the background alone.
        func fill(_ backdrop: NSView) -> NSView {
            backdrop.frame = NSRect(origin: .zero, size: size)
            backdrop.alphaValue = store.barOpacity

            let outer = NSView(frame: NSRect(origin: .zero, size: size))
            outer.addSubview(backdrop)
            stack.translatesAutoresizingMaskIntoConstraints = true
            stack.frame = NSRect(origin: .zero, size: size)
            // Clipped for the same reason as the glass bar: the buttons run
            // taller than the capsule, and the hover pill would spill.
            stack.wantsLayer = true
            stack.layer?.cornerRadius = radius
            stack.layer?.masksToBounds = true
            outer.addSubview(stack)

            // Explicit sizes: fittingSize of a wrapper holding nothing pinned
            // is zero, and the panel's window would collapse.
            outer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                outer.widthAnchor.constraint(equalToConstant: size.width),
                outer.heightAnchor.constraint(equalToConstant: size.height),
            ])
            return outer
        }

        // No glass branch here. buildBar sends the two glass styles to
        // buildGlassBar before ever reaching this, and on a system too old for
        // NSGlassEffectView they fall through to the plain fill below — so the
        // branch that used to sit here could not be reached either way.
        if store.barStyle == .lens {
            let view = LensView()
            view.lens = store.barLens
            view.cornerRadius = radius
            view.wantsLayer = true
            return fill(view)
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

/// A bar button that lights up under the pointer.
///
/// The highlight goes on the layer's background rather than in a sublayer: a
/// sublayer is drawn above the view's own content and would cover the icon,
/// while the background sits beneath it.
///
/// The shape is cut by a mask rather than by the layer's own corner radius,
/// and that is the whole trick. A button is not the size of the slot it sits
/// in: measured, they come out 45 to 49 points tall against a bar of 38, each
/// sized by its own icon, centred so they overhang top and bottom, and the
/// stack clips the overhang away. Every radius set on the layer was therefore
/// computed against a height half as tall again as the one on screen. Half of
/// it drew a disc floating in the middle of the bar; a smaller fraction only
/// shrank the disc, since the rounding still fell inside the visible band —
/// and by a different amount on each button, no two being the same height.
/// Dropping the radius altogether left a hard-cornered block.
///
/// The mask is given the slot instead: the bar's height, which the builder
/// knows and hands over, and the full width between one icon's neighbours,
/// because that is the area the click answers to. The icon sits well inside
/// and is untouched by the mask.
///
/// The fill is square, save at the two ends of the row. A button in the middle
/// has neighbours on both sides and any rounding there would open a gap
/// between one highlight and the next; the outermost pair instead take the
/// capsule's own radius on their outer side, so the highlight follows the
/// shape of the bar where the bar has a shape.
private final class HoverButton: NSButton {
    /// The bar's height, which is not this button's — see above. Zero until
    /// the builder sets it, in which case the mask falls back to the bounds.
    var slotHeight: CGFloat = 0

    /// Which corners follow the capsule. Empty for every button but the two
    /// at the ends; all four when the bar holds a single action.
    var capsuleCorners: CACornerMask = []

    private var area: NSTrackingArea?
    private var hovered = false { didSet { applyHighlight() } }

    /// Registered as .activeAlways on purpose. The bar's panel never becomes
    /// key — it must not, or the application beneath would drop its selection
    /// — and an .activeInKeyWindow area would therefore never fire.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let fresh = NSTrackingArea(rect: .zero,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(fresh)
        area = fresh
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func layout() {
        super.layout()
        applyMask()
        applyHighlight()
    }

    /// Confines whatever the layer draws to the slot this button occupies in
    /// the bar, with the corners rounded against that height.
    private func applyMask() {
        wantsLayer = true
        guard bounds.width > 0, bounds.height > 0 else { return }

        let height = slotHeight > 0 ? min(slotHeight, bounds.height) : bounds.height
        let shape = CALayer()
        shape.frame = CGRect(x: 0, y: (bounds.height - height) / 2,
                             width: bounds.width, height: height)
        // Half the height is the capsule's own radius — the bar is cut to
        // exactly that. Only the corners named get it; the rest stay square.
        shape.cornerRadius = capsuleCorners.isEmpty ? 0 : height / 2
        shape.maskedCorners = capsuleCorners
        // A mask works on the alpha it carries, so it needs to be opaque
        // wherever it should let the layer through. The colour is immaterial.
        shape.backgroundColor = NSColor.black.cgColor
        layer?.mask = shape
    }

    private func applyHighlight() {
        wantsLayer = true
        guard hovered else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        // labelColor is dynamic, so it has to be resolved against the view's
        // own appearance — the bar carries the appearance from settings, which
        // need not be the system's.
        var colour = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
        layer?.backgroundColor = colour
    }
}

    /// The sizes come from the caller: a button must fill the capsule entirely
    /// so clicks register beyond the icon itself. The icon inside keeps its
    /// point size and simply sits centred — nothing changes to the eye.
    /// Which corners of the button at `index` follow the bar's capsule: the
    /// outer pair at each end of the row, none in between. Both pairs when the
    /// row holds one button, since then it is both ends at once.
    ///
    /// Named by side rather than by corner, so it holds whichever way round
    /// the layer's vertical axis runs.
    /// The width the button at `index` gains from the bar's side inset.
    ///
    /// The inset used to sit on the stack, which held the whole row of buttons
    /// clear of the capsule's ends. The hover highlight cannot leave its own
    /// button, so at either end it stopped short of the bar's edge: its rounded
    /// cap sat inside the capsule's, and a sliver of bar showed between the two
    /// curves. Given to the outermost buttons instead, as extra width, the row
    /// spans the capsule end to end — the bar measures the same, and the two
    /// curves now coincide, both being half the height.
    ///
    /// One button takes it at both ends, being both the first and the last.
    private static func endPadding(at index: Int, of count: Int,
                                   inset: CGFloat) -> CGFloat {
        var extra: CGFloat = 0
        if index == 0 { extra += inset }
        if index == count - 1 { extra += inset }
        return extra
    }

    private static func capsuleCorners(at index: Int, of count: Int) -> CACornerMask {
        var mask: CACornerMask = []
        if index == 0 {
            mask.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner])
        }
        if index == count - 1 {
            mask.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
        }
        return mask
    }

    private func makeButton(for action: Action,
                            width: CGFloat, height: CGFloat,
                            corners: CACornerMask) -> NSButton {
        let button = HoverButton(title: "", target: self, action: #selector(perform(_:)))
        // The height asked for here is the bar's, and the button will not end
        // up wearing it — see HoverButton. It is handed over so the highlight
        // can be cut to the slot rather than to the button.
        button.slotHeight = height
        button.capsuleCorners = corners

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

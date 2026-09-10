import AppKit
import SwiftUI

// MARK: - The panel itself

/// A borderless panel that can take keyboard focus.
///
/// A plain NSPanel with .nonactivatingPanel never becomes key, which is right
/// for a menu but wrong for settings: text fields and pickers would take no
/// input at all.
private final class KeyablePanel: NSPanel {
    var wantsKey = false
    override var canBecomeKey: Bool { wantsKey }
}

/// Shows arbitrary SwiftUI content in a panel under a menu bar item.
///
/// AppKit offers NSMenu and NSPopover for this, and neither can be styled:
/// their appearance belongs to the system. So the panel is an ordinary window
/// with our own content, and everything the system would do for free has to be
/// reproduced by hand — dismissing on an outside click and on Escape.
@MainActor
final class FloatingPanel {
    private var panel: KeyablePanel?
    private var dismissMonitor: Any?
    private var keyMonitor: Any?

    var isShown: Bool { panel != nil }

    /// - Parameter takesFocus: whether the content needs keyboard input.
    func show(
        _ content: some View,
        below button: NSStatusBarButton,
        takesFocus: Bool = false
    ) {
        hide()

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = KeyablePanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.wantsKey = takesFocus
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        // Out of every capture, for the same reason as the bar's own panel:
        // the preview in settings is a lens too, and would otherwise film the
        // settings window it sits in.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting

        panel.setFrameTopLeftPoint(anchor(below: button, width: hosting.frame.width))
        if takesFocus {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel

        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 53 else { return event }   // 53 = Escape
            MainActor.assumeIsolated { [weak self] in self?.hide() }
            return nil
        }
    }

    func hide() {
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        dismissMonitor = nil
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Places the panel under the icon, keeping it on screen at either edge.
    private func anchor(below button: NSStatusBarButton, width: CGFloat) -> NSPoint {
        guard let window = button.window else { return .zero }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = frame.midX - width / 2
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        }
        return NSPoint(x: x, y: frame.minY - 6)
    }
}

// MARK: - Shared appearance

/// The dark rounded chrome shared by the menu and the settings panel.
///
/// The dark scheme is forced rather than followed: the row highlight and the
/// hairline edge are tuned for a dark ground, and on a light one they would
/// read as smudges.
struct PanelChrome: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.34)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    // Without this edge the panel bleeds into a dark background
                    // and loses its shape.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
            .preferredColorScheme(.dark)
    }
}

extension View {
    func panelChrome(radius: CGFloat = 12) -> some View {
        modifier(PanelChrome(radius: radius))
    }
}

// MARK: - The menu

/// One row of the menu.
struct MenuEntry: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    /// Shown on the right, e.g. "⌘R". Empty for rows without a shortcut.
    var shortcut: String = ""
    /// Marks a destructive row so it can be tinted differently.
    var isDestructive = false
    let action: () -> Void
}

struct MenuPanelView: View {
    let entries: [MenuEntry]
    let dismiss: () -> Void

    @State private var hovered: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                row(entry)
            }
        }
        // Rows sit flush and run the full width, so the menu reads as one
        // piece rather than a stack of separate tiles. Only a little air is
        // left top and bottom; taking it sideways too would inset every
        // highlight and bring the seams back.
        .padding(.vertical, 5)
        .frame(width: 232)
        // A full-width highlight would otherwise square off the top and
        // bottom corners, which are still curving where the first and last
        // rows sit.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .panelChrome()
    }

    private func row(_ entry: MenuEntry) -> some View {
        Button {
            dismiss()
            entry.action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(entry.isDestructive ? Color.red.opacity(0.9) : .white.opacity(0.85))
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer(minLength: 8)
                if !entry.shortcut.isEmpty {
                    Text(entry.shortcut)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            // The inset the panel's own padding used to give is carried by
            // the row instead, so the text keeps its margin while the
            // highlight still reaches the edges.
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(hovered == entry.id ? 0.14 : 0))
            // Without this the row only reacts on the glyphs themselves.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
    }
}

// MARK: - A picker of our own

extension View {
    /// Strips a system popover's own background so our chrome is what shows.
    /// Without it the system draws a light vibrant plate around dark content.
    ///
    /// The modifier only exists from macOS 13.3 while the app targets 13.0, so
    /// it is guarded: on older systems the plate stays, but nothing breaks.
    @ViewBuilder
    func clearPopoverBackground() -> some View {
        if #available(macOS 13.3, *) {
            self.presentationBackground(.clear)
        } else {
            self
        }
    }
}

/// A dropdown in the same language as the menu.
///
/// SwiftUI's Picker draws its list with a system menu, which cannot be styled —
/// the same limitation that forced the menu itself to be rebuilt. So the list
/// is ours: a button showing the current choice, and a popover of rows.
struct StyledPicker<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    @State private var open = false
    @State private var hovered: Int?

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Button {
                open = true
            } label: {
                HStack(spacing: 3) {
                    Text(currentLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                list
                    .panelChrome(radius: 10)
                    .clearPopoverBackground()
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    selection = option.value
                    open = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                            .opacity(option.value == selection ? 1 : 0)
                        Text(option.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.95))
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(hovered == index ? 0.14 : 0))
                    // Without this the row only reacts on the glyphs themselves.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 230)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

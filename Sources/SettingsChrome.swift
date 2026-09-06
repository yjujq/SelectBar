import SwiftUI

/// The vocabulary the settings panel is drawn from.
///
/// AppKit's own controls are not used here for the same reason the menu was
/// rebuilt by hand in MenuPanel.swift: their appearance belongs to the system
/// and cannot be brought in line with the dark chrome. What the system would
/// give for free — a section header, a segmented control, a search field — is
/// therefore assembled from primitives.
enum Chrome {
    /// One scale, from the text down to the hairline. Every surface in the
    /// panel is white at some opacity over the dark ground rather than a
    /// colour of its own, so the whole thing stays coherent whatever shows
    /// through the material behind it.
    static let text     = Color.white.opacity(0.95)
    static let dim      = Color.white.opacity(0.55)
    static let faint    = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.10)
    static let fill     = Color.white.opacity(0.06)
    static let hover    = Color.white.opacity(0.10)
    static let picked   = Color.white.opacity(0.18)
    /// The header band, a shade lighter than the body.
    static let band     = Color.white.opacity(0.04)

    /// The side margin every row shares, so labels line up down the panel.
    static let gutter: CGFloat = 16

    /// The panel's own size. The width is set by the widest row — a label with
    /// a four-segment control beside it — rather than chosen for looks.
    static let width: CGFloat = 430
    static let height: CGFloat = 500
}

/// A one-pixel rule. Divider() carries the system's own colour, which reads as
/// a smudge on this ground.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Chrome.hairline)
            .frame(height: 1)
    }
}

// MARK: - Header

/// The breadcrumb bar: a gear, then the path to the page on screen.
///
/// Every crumb but the last is a button back to that level. The last one is
/// where we are and is drawn as plain text — a button that led nowhere would
/// still light up under the pointer and promise a move that never happens.
struct CrumbBar: View {
    let crumbs: [String]
    var onCrumb: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Chrome.dim)

            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Chrome.faint)
                }
                if index == crumbs.count - 1 {
                    Text(crumb)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.text)
                        .lineLimit(1)
                } else {
                    CrumbButton(title: crumb) { onCrumb(index) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Chrome.gutter)
        .frame(height: 42)
        .background(Chrome.band)
    }
}

private struct CrumbButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(hovered ? Chrome.text : Chrome.dim)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Search

/// The search row, with room for one button on the right.
///
/// The focus binding is handed in rather than held here: the panel wants to
/// put the caret in the field on ⌘F, and a FocusState owned by this view
/// would be beyond its reach.
struct SearchRow<Accessory: View>: View {
    @Binding var text: String
    var placeholder: String
    var focused: FocusState<Bool>.Binding
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            // No magnifier glyph: the placeholder already says what the field
            // is for, and the icon only ate into a line that has a button on
            // the other end.
            TextField("", text: $text, prompt:
                Text(placeholder).foregroundColor(Chrome.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Chrome.text)
                .focused(focused)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.faint)
                }
                .buttonStyle(.plain)
            }

            accessory()
        }
        .padding(.horizontal, Chrome.gutter)
        .frame(height: 46)
    }
}

// MARK: - Buttons

/// A bordered pill: the shape every standalone button in the panel wears.
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var isDestructive = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isDestructive ? Color.red.opacity(0.85) : Chrome.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Chrome.hover : Chrome.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Chrome.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Sections and rows

/// A section heading: the grey line that breaks the list into groups.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(Chrome.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Chrome.gutter)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }
}

/// A settings row: an optional switch, the label, and whatever control the
/// setting needs on the right.
///
/// The switch sits before the label rather than after it, as in the panel this
/// is modelled on. Everything that can be turned on and off then shares one
/// column down the left, and the eye finds the state without reading.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var toggle: Binding<Bool>? = nil
    var enabled = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 11) {
            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // A neutral track keeps the row monochrome; the accent
                    // colour was the one saturated thing in the panel.
                    .tint(Color.white.opacity(0.34))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Chrome.text : Chrome.faint)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.faint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.horizontal, Chrome.gutter)
        .padding(.vertical, 7)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil,
         toggle: Binding<Bool>? = nil, enabled: Bool = true) {
        self.init(title: title, subtitle: subtitle,
                  toggle: toggle, enabled: enabled) { EmptyView() }
    }
}

/// A row that leads somewhere: an icon in a tile, the title, a chevron.
struct NavRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var badge: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Chrome.text)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Chrome.fill)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Chrome.text)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.faint)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Chrome.dim)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.faint)
            }
            .padding(.horizontal, Chrome.gutter)
            .padding(.vertical, 9)
            .background(hovered ? Chrome.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Segmented control

/// The choice laid out in full instead of hidden behind a dropdown.
///
/// Worth the width only while the options are few and their labels short; the
/// long ones — a selection context spelled out in a sentence — still go to
/// StyledPicker.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var enabled = true

    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                // A separator between neighbours, but not where the selected
                // pill already draws its own edge.
                if index > 0 {
                    Rectangle()
                        .fill(touchesSelection(index) ? Color.clear : Chrome.hairline)
                        .frame(width: 1, height: 14)
                }
                segment(index: index, option: option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Chrome.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Chrome.hairline, lineWidth: 1)
        )
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }

    private func segment(index: Int, option: (value: Value, label: String)) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Chrome.text : Chrome.dim)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Chrome.picked
                                         : (hovered == index ? Chrome.hover : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
    }

    /// Whether the seam at `index` runs alongside the selected segment.
    private func touchesSelection(_ index: Int) -> Bool {
        guard let selected = options.firstIndex(where: { $0.value == selection }) else {
            return false
        }
        return index == selected || index == selected + 1
    }
}

// MARK: - Sliders

/// A slider row: the label, the track, and the value read out at the end.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var enabled = true

    init(title: String, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double = 0.05, enabled: Bool = true) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.enabled = enabled
    }

    var body: some View {
        HStack(spacing: 11) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Chrome.text : Chrome.faint)
                .frame(width: 62, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(Color.white.opacity(0.45))
            Text("\(Int(value * 100))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Chrome.dim)
                .frame(width: 40, alignment: .trailing)
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .padding(.horizontal, Chrome.gutter)
        .padding(.vertical, 7)
    }
}

/// A single-line text field in the panel's own dress.
struct FieldRow: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 11) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Chrome.text)
                .frame(width: 62, alignment: .leading)
            TextField("", text: $text, prompt:
                Text(placeholder).foregroundColor(Chrome.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Chrome.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Chrome.fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Chrome.hairline, lineWidth: 1)
                )
        }
        .padding(.horizontal, Chrome.gutter)
        .padding(.vertical, 7)
    }
}

/// An explanatory line under a control.
struct HintText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Chrome.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Chrome.gutter)
            .padding(.bottom, 6)
    }
}

import AppKit
import ApplicationServices

/// What is under the cursor at the moment the mouse is released.
enum Context {
    /// There is selected text. `editable` says whether typing is allowed here,
    /// which decides whether to offer pasting over the selection.
    case selection(Selection, editable: Bool)
    /// The caret sits in an editable field with nothing selected, so offering
    /// a paste makes sense. `rect` is the caret's rectangle.
    case editableField(NSRect?)
}

/// What could be learned about the current selection.
struct Selection {
    let text: String
    /// The selection rectangle in Cocoa coordinates (origin at bottom left).
    /// nil when the app reported no geometry — the bar then sits at the cursor.
    let rect: NSRect?
}

enum AX {
    /// Whether Accessibility access is granted. `prompt` shows the system dialog.
    static func trusted(prompt: Bool) -> Bool {
        // The key is spelled out deliberately: the system constant is declared
        // as a global variable, and Swift 6 will not let such things be read
        // from any context. Its value is fixed.
        let options = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Cap how long we wait for an answer: a hung application must not hang
    /// us on every click.
    static func setTimeout(_ seconds: Float, for element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Turn on Accessibility support in an application that keeps it off for
    /// speed — Chrome and everything built on it does exactly that.
    ///
    /// There are two signals and both are needed. `AXManualAccessibility` was
    /// understood by Chromium-based apps, but Chrome rejected it: measurement
    /// returned code -25205, meaning "attribute not supported".
    /// `AXEnhancedUserInterface` is older and more general — it is what
    /// VoiceOver uses to switch support on, and nearly everything honours it.
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}

/// Reads the selected text through Accessibility.
///
/// There is deliberately no synthetic ⌘C here: it would be an action rather
/// than a read, and in applications such as Finder it would copy the selected
/// files. The price of refusing is that applications which do not expose their
/// selection through Accessibility show no bar at all.
final class SelectionReader {
    /// Whether to show the paste bar when clicking an empty editable field.
    var offerPaste = true

    func read() -> Context? {
        let system = AXUIElementCreateSystemWide()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            AX.enableManualAccessibility(pid: pid)
        }
        let focused = (AX.attribute(system, kAXFocusedUIElementAttribute as String)).map {
            $0 as! AXUIElement
        }

        // Whether typing is allowed here, which decides whether to offer
        // pasting next to the selection.
        let editable = focused.map { isEditable($0) } ?? false

        if let focused, let selection = selectedText(in: focused) {
            return .selection(selection, editable: editable)
        }

        // The focused element says nothing. In applications with web views the
        // selection may live elsewhere, so we search the window's subtree.
        // First the focused element's own subtree: for panels such as Quick
        // Look the app reports a completely different window as focused, and a
        // search from there goes down the wrong tree.
        if let focused {
            var budget = 400
            if let found = search(focused, depth: 0, budget: &budget) {
                return .selection(found, editable: editable)
            }
            // Go up to this element's window and try from there.
            if let windowRef = AX.attribute(focused, kAXWindowAttribute as String) {
                var budget2 = 400
                if let found = search(windowRef as! AXUIElement, depth: 0, budget: &budget2) {
                    return .selection(found, editable: editable)
                }
            }
        }

        if let found = selectedTextInFocusedWindow() {
            return .selection(found, editable: editable)
        }

        // No selection. If the caret is in an input field, offer a paste; no
        // ⌘C fallback is needed here, as there is nothing to copy anyway.
        if offerPaste, let focused, isEditable(focused) {
            return .editableField(caretRect(in: focused))
        }

        return nil
    }

    /// Walk a window's subtree looking for an element with a non-empty
    /// selection. The walk is capped by node count and depth: a large window's
    /// tree can be enormous, and we run on every mouse release.
    private func selectedTextInFocusedWindow() -> Selection? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AX.setTimeout(0.2, for: app)
        guard let windowRef = AX.attribute(app, kAXFocusedWindowAttribute as String) else { return nil }

        var budget = 400
        return search(windowRef as! AXUIElement, depth: 0, budget: &budget)
    }

    private func search(_ element: AXUIElement, depth: Int, budget: inout Int) -> Selection? {
        guard budget > 0, depth <= 12 else { return nil }
        budget -= 1

        if let textRef = AX.attribute(element, kAXSelectedTextAttribute as String),
           let text = textRef as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Selection(text: text, rect: selectionRect(of: element))
        }
        if let viaMarkers = selectedTextViaMarkers(in: element) { return viaMarkers }
        if let viaRange = selectedTextViaRange(in: element) { return viaRange }

        guard let childrenRef = AX.attribute(element, kAXChildrenAttribute as String),
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = search(child, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }

    /// Whether text can be typed into this element.
    ///
    /// Only asking "is this attribute settable" gives an authoritative answer.
    /// The role cannot serve as the sign: `AXTextArea` is worn by read-only
    /// areas too — log viewers, help, parts of web pages. The code used to fall
    /// back to the role on a negative answer and offered pasting where it could
    /// not possibly work.
    func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if status == .success {
            return settable.boolValue          // we have an answer, no need for the role
        }
        // The element could not answer. Only now the role as a fallback.
        guard let roleRef = AX.attribute(element, kAXRoleAttribute as String),
              let role = roleRef as? String else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    /// Whether the focused element is editable right now. Needed so a paste is
    /// only offered where it can actually happen.
    func focusedIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let focusedRef = AX.attribute(system, kAXFocusedUIElementAttribute as String) else {
            return false
        }
        return isEditable(focusedRef as! AXUIElement)
    }

    /// The caret rectangle — a zero-length range has geometry too.
    private func caretRect(in element: AXUIElement) -> NSRect? {
        selectionRect(of: element)
    }

    // MARK: - Accessibility

    /// Selection through WebKit text markers.
    ///
    /// In web views (Mail, Safari, Help) the AXSelectedText attribute does not
    /// exist at all — the selection is published as a range of text markers,
    /// which a parameterised query turns into a string.
    private func selectedTextViaMarkers(in element: AXUIElement) -> Selection? {
        guard let markerRange = AX.attribute(element, "AXSelectedTextMarkerRange") else {
            return nil
        }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForTextMarkerRange" as CFString, markerRange, &textRef) == .success,
              let text = textRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Selection(text: text, rect: markerBounds(of: element, range: markerRange))
    }

    /// Selection geometry by the same marker route.
    private func markerBounds(of element: AXUIElement, range: CFTypeRef) -> NSRect? {
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, range, &boundsRef) == .success,
              let bounds = boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return Self.flipToCocoa(rect)
    }

    /// Fallback: the text is taken by the selected range.
    ///
    /// Terminal advertises AXSelectedText among its attributes but returns an
    /// empty string for it — verified from the log. The real text is only
    /// reachable through AXStringForRange with the range from
    /// AXSelectedTextRange. Applications that draw their own text, rather than
    /// using the system's, behave this way.
    private func selectedTextViaRange(in element: AXUIElement) -> Selection? {
        guard let rangeRef = AX.attribute(element, kAXSelectedTextRangeAttribute as String) else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else {
            return nil
        }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element,
                  kAXStringForRangeParameterizedAttribute as CFString,
                  rangeRef,
                  &textRef) == .success,
              let text = textRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Selection(text: text, rect: selectionRect(of: element))
    }

    private func selectedText(in focused: AXUIElement) -> Selection? {
        if let viaMarkers = selectedTextViaMarkers(in: focused) { return viaMarkers }
        guard let textRef = AX.attribute(focused, kAXSelectedTextAttribute as String),
              let text = textRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return selectedTextViaRange(in: focused)
        }
        return Selection(text: text, rect: selectionRect(of: focused))
    }

    /// Selection geometry: range to rectangle. Not available everywhere.
    private func selectionRect(of element: AXUIElement) -> NSRect? {
        guard let rangeRef = AX.attribute(element, kAXSelectedTextRangeAttribute as String) else {
            return nil
        }
        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRef,
            &boundsRef
        )
        guard status == .success, let boundsValue = boundsRef else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width >= 0 else {
            return nil
        }
        return Self.flipToCocoa(rect)
    }

    /// Accessibility gives coordinates with the origin at the top left of the
    /// main screen while Cocoa's is at the bottom left, so we flip them.
    static func flipToCocoa(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(x: rect.origin.x,
                      y: primary.frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

}

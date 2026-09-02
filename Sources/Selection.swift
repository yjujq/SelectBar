import AppKit
import ApplicationServices

/// Что происходит под курсором в момент отпускания мыши.
enum Context {
    /// Есть выделенный текст. editable — можно ли в это место вводить:
    /// от этого зависит, предлагать ли вставку поверх выделения.
    case selection(Selection, editable: Bool)
    /// Курсор стоит в редактируемом поле, но ничего не выделено —
    /// уместно предложить вставку. rect — прямоугольник каретки.
    case editableField(NSRect?)
}

/// Что удалось узнать о текущем выделении.
struct Selection {
    let text: String
    /// Прямоугольник выделения в координатах Cocoa (начало отсчёта снизу слева).
    /// nil, если приложение не сообщило геометрию — тогда панель ставится у курсора.
    let rect: NSRect?
}

enum AX {
    /// Выдан ли доступ в «Универсальный доступ». prompt = показать системное окно.
    static func trusted(prompt: Bool) -> Bool {
        // Ключ задан строкой намеренно: системная константа объявлена как
        // глобальная переменная, а такие Swift 6 читать из любого контекста
        // не разрешает. Значение у неё фиксированное.
        let options = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Ограничиваем ожидание ответа: подвисшее приложение не должно
    /// подвешивать нас на каждом клике.
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

    /// Chromium и Electron не отдают выделение, пока им явно не включишь
    /// поддержку Accessibility этим недокументированным атрибутом.
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// Достаёт выделенный текст через Accessibility.
///
/// Синтетического ⌘C здесь намеренно нет: он был бы действием, а не чтением,
/// и в приложениях вроде Finder приводил бы к копированию выделенных объектов.
/// Цена отказа — приложения, не отдающие выделение через Accessibility,
/// панель не показывают вовсе.
final class SelectionReader {
    /// Показывать ли панель вставки при клике в пустое редактируемое поле.
    var offerPaste = true

    func read() -> Context? {
        Log.write("--- отпускание мыши ---")
        let system = AXUIElementCreateSystemWide()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            AX.enableManualAccessibility(pid: pid)
        }
        let focused = (AX.attribute(system, kAXFocusedUIElementAttribute as String)).map {
            $0 as! AXUIElement
        }

        if Log.enabled, let focused { logElement(focused) }

        // Можно ли вводить в это место: от этого зависит, предлагать ли
        // вставку рядом с выделением.
        let editable = focused.map { isEditable($0) } ?? false

        if let focused, let selection = selectedText(in: focused) {
            Log.write("выделение получено: \(selection.text.count) символов")
            return .selection(selection, editable: editable)
        }

        // Сфокусированный элемент молчит. В приложениях с веб-представлениями
        // выделение может жить не в нём — ищем по поддереву окна.
        // Сначала поддерево самого сфокусированного элемента: у панелей вроде
        // быстрого просмотра приложение считает «сфокусированным окном» совсем
        // другое окно, и поиск от него уходит не в то дерево.
        if let focused {
            var budget = 400
            if let found = search(focused, depth: 0, budget: &budget) {
                Log.write("выделение найдено в поддереве фокуса: \(found.text.count) символов")
                return .selection(found, editable: editable)
            }
            // Поднимаемся к окну этого элемента и пробуем от него.
            if let windowRef = AX.attribute(focused, kAXWindowAttribute as String) {
                var budget2 = 400
                if let found = search(windowRef as! AXUIElement, depth: 0, budget: &budget2) {
                    Log.write("выделение найдено в окне фокуса: \(found.text.count) символов")
                    return .selection(found, editable: editable)
                }
            }
        }

        if let found = selectedTextInFocusedWindow() {
            Log.write("выделение найдено в поддереве: \(found.text.count) символов")
            return .selection(found, editable: editable)
        }
        Log.write("выделения не найдено нигде")

        // Выделения нет. Если курсор в поле для ввода — предложим вставку,
        // и запасной путь через ⌘C тут не нужен: копировать всё равно нечего.
        if offerPaste, let focused, isEditable(focused) {
            return .editableField(caretRect(in: focused))
        }

        return nil
    }

    /// Полный разбор элемента: роль и все атрибуты, которые он умеет отдавать.
    /// Именно этот список отвечает, можно ли отсюда достать выделение.
    private func logElement(_ element: AXUIElement) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let role = (AX.attribute(element, kAXRoleAttribute as String) as? String) ?? "?"
        let subrole = (AX.attribute(element, kAXSubroleAttribute as String) as? String) ?? "-"
        var names: CFArray?
        var attributes: [String] = []
        if AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] {
            attributes = list
        }
        Log.write("приложение=\(app) роль=\(role) подроль=\(subrole)")
        Log.write("атрибуты (\(attributes.count)): \(attributes.joined(separator: ", "))")
    }

    /// Обойти поддерево окна в поисках элемента с непустым выделением.
    /// Обход ограничен по числу узлов и глубине: дерево большого окна может
    /// быть огромным, а мы работаем на каждом отпускании мыши.
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

    /// Можно ли в этот элемент вводить текст.
    ///
    /// Авторитетный ответ даёт только запрос «можно ли записать значение».
    /// Роль признаком служить не может: `AXTextArea` носят и области, доступные
    /// лишь для чтения — просмотрщики логов, справка, части веб-страниц. Раньше
    /// код при отрицательном ответе всё равно смотрел на роль и предлагал
    /// вставку туда, где она заведомо не сработает.
    func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if status == .success {
            return settable.boolValue          // ответ получен — роль не спрашиваем
        }
        // Элемент не смог ответить. Только теперь роль как запасной признак.
        guard let roleRef = AX.attribute(element, kAXRoleAttribute as String),
              let role = roleRef as? String else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    /// Редактируем ли сейчас сфокусированный элемент. Нужно, чтобы предлагать
    /// вставку только там, где она действительно выполнима.
    func focusedIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let focusedRef = AX.attribute(system, kAXFocusedUIElementAttribute as String) else {
            return false
        }
        return isEditable(focusedRef as! AXUIElement)
    }

    /// Прямоугольник каретки — диапазон нулевой длины тоже имеет геометрию.
    private func caretRect(in element: AXUIElement) -> NSRect? {
        selectionRect(of: element)
    }

    // MARK: - Accessibility

    /// Выделение через маркеры WebKit.
    ///
    /// В веб-представлениях (Почта, Safari, справка) атрибута AXSelectedText
    /// не существует вовсе — выделение публикуется диапазоном текстовых
    /// маркеров, который превращается в строку параметризованным запросом.
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

    /// Геометрия выделения тем же маркерным путём.
    private func markerBounds(of element: AXUIElement, range: CFTypeRef) -> NSRect? {
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForTextMarkerRange" as CFString, range, &boundsRef) == .success,
              let bounds = boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        return Self.flipToCocoa(rect)
    }

    /// Запасной путь: текст берётся по выделенному диапазону.
    ///
    /// Терминал заявляет AXSelectedText в списке атрибутов, но по нему отдаёт
    /// пустую строку — проверено по журналу. Настоящий текст достаётся только
    /// запросом AXStringForRange с диапазоном из AXSelectedTextRange. Так ведут
    /// себя приложения, рисующие текст сами, а не средствами системы.
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
        Log.write("текст получен по диапазону: \(text.count) символов")
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

    /// Геометрия выделения: диапазон -> прямоугольник. Доступно не везде.
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

    /// Accessibility отдаёт координаты с началом в левом верхнем углу главного
    /// экрана, у Cocoa начало снизу слева — переворачиваем.
    static func flipToCocoa(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(x: rect.origin.x,
                      y: primary.frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

}

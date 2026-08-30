import AppKit
import IOKit.hid

/// Слежение за клавиатурой требует отдельного права «Мониторинг ввода».
/// Это не то же самое, что «Универсальный доступ»: без него глобальный монитор
/// не получает событий клавиш и молчит, не сообщая об ошибке.
enum InputMonitoring {
    static var granted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Системное окно с запросом показывается только один раз. Если его уже
    /// отклоняли, право включается вручную в настройках.
    @discardableResult
    static func request() -> Bool {
        if granted { return true }
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        return granted
    }

    static func openSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

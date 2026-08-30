import AppKit
import ApplicationServices

/// Замечает появление баннеров уведомлений.
///
/// Баннеры рисует отдельный системный процесс NotificationCenter. Подписываемся
/// через Accessibility на создание его окон: так срабатывает на уведомление от
/// любого приложения, и не нужен доступ к базе уведомлений.
@MainActor
final class NotificationWatcher {
    /// Вызывается на каждый замеченный баннер.
    var onBanner: (() -> Void)?

    private var observer: AXObserver?
    private var watchedPID: pid_t = 0
    private var retryTimer: Timer?
    private var lastFired = Date.distantPast

    /// Одно уведомление может породить несколько окон — не мигаем на каждое.
    private let cooldown: TimeInterval = 1.0

    func start() {
        attach()
        // Процесс уведомлений может перезапускаться — periодически проверяем.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.attachIfNeeded() }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        detach()
    }

    private var notificationCenterPID: pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }?.processIdentifier
    }

    private func attachIfNeeded() {
        guard let pid = notificationCenterPID else { return }
        if observer == nil || pid != watchedPID { attach() }
    }

    private func attach() {
        detach()
        guard let pid = notificationCenterPID else {
            Log.write("центр уведомлений не найден")
            return
        }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.handleBanner() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
            Log.write("не удалось создать наблюдателя для pid \(pid)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AXObserverAddNotification(observer, app,
                                               kAXWindowCreatedNotification as CFString, context)
        guard status == .success else {
            Log.write("подписка на окна не удалась: \(status.rawValue)")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        watchedPID = pid
        Log.write("слежу за уведомлениями, pid \(pid)")
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        watchedPID = 0
    }

    private func handleBanner() {
        let now = Date()
        guard now.timeIntervalSince(lastFired) > cooldown else { return }
        lastFired = now
        Log.write("замечен баннер уведомления")
        onBanner?()
    }
}

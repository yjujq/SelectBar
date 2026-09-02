import AppKit

/// Замечает доставку уведомлений по системному журналу.
///
/// Раньше здесь была подписка через Accessibility на создание окон процесса
/// центра уведомлений. Замеры показали, что так ловится только панель,
/// открываемая щелчком по часам: за время проверки пришло два десятка писем,
/// а событий не было ни одного — баннер не создаёт ни окна, ни даже элемента.
/// Поэтому менять пришлось не условие отбора, а сам способ слежения.
///
/// Штатный путь — системный журнал. Служба `usernoted` на каждое доставленное
/// уведомление пишет строку с записью вида `NotificationRecord app:"…"`.
/// Читаем поток командой `log stream`: обычная программа, никаких частных
/// интерфейсов и никаких особых разрешений.
@MainActor
final class NotificationWatcher {
    /// Вызывается на каждое замеченное уведомление.
    var onBanner: (() -> Void)?

    private var task: Process?
    private var tail = ""
    private var lastFired = Date.distantPast

    /// Одно уведомление даёт в журнале несколько строк — не мигаем на каждую.
    private let cooldown: TimeInterval = 1.5

    /// Метка в строке журнала, по которой опознаётся доставка.
    private static let marker = "NotificationRecord app:\""

    func start() {
        stop()
        reapStrays()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            // Сужаем поток до нужной службы: иначе через нас пошёл бы весь
            // системный журнал, а это заметная нагрузка на ровном месте.
            "--predicate", "process == \"usernoted\"",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Обработчик вызывается в фоновой очереди, поэтому к объекту,
        // привязанному к главному потоку, обращаемся только после перехода.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(chunk) }
            }
        }

        do {
            try process.run()
            task = process
        } catch {
            NSLog("SelectBar: не удалось запустить чтение журнала: \(error)")
        }
    }

    /// Убрать осиротевшие процессы чтения журнала.
    ///
    /// При обычном выходе дочерний процесс завершает `stop()`, вызываемый из
    /// applicationWillTerminate. Но при аварийном завершении или снятии
    /// сигналом обработчик выхода не отрабатывает, и процесс остаётся жить,
    /// перейдя к launchd. Сироты незаметны и бесполезны, а копятся с каждым
    /// таким разом — поэтому подчищаем их при запуске.
    private func reapStrays() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Строка совпадения включает предикат целиком: под неё не подпадёт
        // ничей посторонний `log stream`.
        pkill.arguments = ["-f", "log stream --style compact --predicate process == \"usernoted\""]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func stop() {
        if let task, task.isRunning { task.terminate() }
        task = nil
        tail = ""
    }

    /// Разбор очередного куска потока.
    ///
    /// Кусок может оборваться на середине строки, поэтому неполный хвост
    /// сохраняем и приклеиваем к следующему.
    private func ingest(_ chunk: String) {
        var lines = (tail + chunk).components(separatedBy: "\n")
        tail = lines.removeLast()

        for line in lines {
            guard line.contains(Self.marker) else { continue }
            let now = Date()
            guard now.timeIntervalSince(lastFired) > cooldown else { continue }
            lastFired = now

            onBanner?()
        }
    }
}

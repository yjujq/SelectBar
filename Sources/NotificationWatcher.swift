import AppKit

/// Notices notification delivery through the system log.
///
/// This used to subscribe through Accessibility to window creation in the
/// notification centre process. Measurement showed that only catches the panel
/// opened by clicking the clock: two dozen messages arrived during the test and
/// not a single event fired — a banner creates neither a window nor even an
/// element. So what had to change was not the filter but the watching method.
///
/// The supported path is the system log. For every delivered notification the
/// `usernoted` service writes a line containing `NotificationRecord app:"…"`.
/// We read the stream with `log stream`: an ordinary tool, no private
/// interfaces and no special permissions.
@MainActor
final class NotificationWatcher {
    /// Called for every notification noticed.
    var onBanner: (() -> Void)?

    private var task: Process?
    private var tail = ""
    private var lastFired = Date.distantPast

    /// One notification produces several log lines — do not blink on each.
    private let cooldown: TimeInterval = 1.5

    /// The marker in a log line by which a delivery is recognised.
    private static let marker = "NotificationRecord app:\""

    func start() {
        stop()
        reapStrays()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            // Narrow the stream to the one service: otherwise the whole
            // system log would flow through us, a real load for nothing.
            "--predicate", "process == \"usernoted\"",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // The handler runs on a background queue, so we only touch the
        // main-actor object after hopping onto the main thread.
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
            NSLog("SelectBar: could not start reading the log: \(error)")
        }
    }

    /// Reap orphaned log-reading processes.
    ///
    /// On an ordinary quit the child is terminated by `stop()`, called from
    /// applicationWillTerminate. But on a crash or a signal the exit handler
    /// never runs, and the process lives on, reparented to launchd. Such
    /// orphans are invisible and useless yet accumulate every such time — so
    /// we clean them up at startup.
    private func reapStrays() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // The match string includes the whole predicate: nobody else's
        // `log stream` will fall under it.
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

    /// Parsing the next chunk of the stream.
    ///
    /// A chunk can break mid-line, so an incomplete tail is kept and glued
    /// onto the next one.
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

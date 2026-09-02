import AppKit

/// Что играет в системе — через приватный MediaRemote.
///
/// Публичного способа узнать это нет. Apple к тому же ограничила доступ к
/// этим сведениям для приложений без особого разрешения, поэтому источник
/// может молчать даже при работающем воспроизведении: тогда строка просто
/// не показывается.
@MainActor
final class NowPlaying {
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void

    /// Вызывается с описанием трека либо с nil, когда играть нечего.
    var onChange: ((String?) -> Void)?

    private var getInfo: GetInfo?
    private var timer: Timer?
    private var last: String?

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return }
        getInfo = unsafeBitCast(symbol, to: GetInfo.self)
    }

    var available: Bool { getInfo != nil }

    func start(interval: TimeInterval = 2) {
        guard available else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let getInfo else { return }
        getInfo(DispatchQueue.main) { [weak self] info in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = Self.describe(info as? [String: Any])
                guard text != self.last else { return }
                self.last = text
                self.onChange?(text)
            }
        }
    }

    /// Собираем «исполнитель — название» из полей MediaRemote.
    private static func describe(_ info: [String: Any]?) -> String? {
        guard let info else { return nil }
        func string(_ suffix: String) -> String? {
            guard let key = info.keys.first(where: { $0.hasSuffix(suffix) }),
                  let value = info[key] as? String,
                  !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        let title = string("Title")
        let artist = string("Artist")
        switch (artist, title) {
        case let (a?, t?): return "\(a) — \(t)"
        case let (nil, t?): return t
        default: return nil
        }
    }
}

/// Бегущая строка для строки меню: показывает окно фиксированной ширины
/// и сдвигает текст по кругу.
@MainActor
final class Marquee {
    private var source = ""
    private var offset = 0
    private var timer: Timer?

    /// Сколько знаков видно разом.
    var window = 24
    var onFrame: ((String) -> Void)?

    func show(_ text: String?) {
        guard let text, !text.isEmpty else {
            stop()
            onFrame?("")
            return
        }
        // Разделитель нужен, чтобы конец строки не слипался с началом.
        source = text + "   •   "
        offset = 0
        guard source.count > window else {
            stop()
            onFrame?(text)
            return
        }
        start()
    }

    private func start() {
        timer?.invalidate()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !source.isEmpty else { return }
        let chars = Array(source)
        var frame = ""
        for i in 0..<min(window, chars.count) {
            frame.append(chars[(offset + i) % chars.count])
        }
        offset = (offset + 1) % chars.count
        onFrame?(frame)
    }
}

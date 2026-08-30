import AppKit

/// Подсветка клавиатуры через приватный CoreBrightness.
/// Публичного API нет; методы класса выяснены перечислением через среду
/// выполнения, а не подобраны наугад.
@objc private protocol KeyboardBrightnessAPI {
    func copyKeyboardBacklightIDs() -> NSArray?
    func brightnessForKeyboard(_ keyboard: UInt64) -> Float
    func setBrightness(_ brightness: Float, forKeyboard keyboard: UInt64) -> Bool
    func setBrightness(_ brightness: Float, fadeSpeed: Int32, commit: Bool,
                       forKeyboard keyboard: UInt64) -> Bool
}

@MainActor
enum Lights {
    private static var busy = false

    // MARK: - Клавиатура

    private static let keyboard: (client: KeyboardBrightnessAPI, id: UInt64)? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            return nil
        }
        let client = unsafeBitCast(cls.init(), to: KeyboardBrightnessAPI.self)
        guard let ids = client.copyKeyboardBacklightIDs() as? [NSNumber],
              let first = ids.first else { return nil }
        return (client, first.uint64Value)
    }()

    static var available: Bool { keyboard != nil }

    private static func setKeyboard(_ level: Float) {
        guard let keyboard else { return }
        // Скорость затухания 0 с немедленной фиксацией: иначе система
        // сглаживает переход и на быстром такте свет не доходит до края.
        _ = keyboard.client.setBrightness(level, fadeSpeed: 0, commit: true,
                                          forKeyboard: keyboard.id)
    }

    /// Мигать подсветкой клавиатуры заданное время, затем вернуть как было.
    /// Такт намеренно неторопливый: у светодиодов есть инерция разгорания,
    /// и на частом мигании свет не успевает дойти до края.
    static func blink(duration: Duration = .seconds(7),
                      interval: Duration = .milliseconds(500)) async {
        guard !busy else { return }        // повторное нажатие не наслаивается
        busy = true
        defer { busy = false }

        let originalKeyboard = keyboard.map { $0.client.brightnessForKeyboard($0.id) }

        // Считаем по времени, а не по числу вспышек: длительность задана
        // напрямую, и она не поедет при смене темпа мигания.
        let clock = ContinuousClock()
        let start = clock.now
        repeat {
            setKeyboard(0)
            try? await Task.sleep(for: interval)
            setKeyboard(1)
            try? await Task.sleep(for: interval)
        } while clock.now - start < duration

        if let originalKeyboard { setKeyboard(originalKeyboard) }
    }
}

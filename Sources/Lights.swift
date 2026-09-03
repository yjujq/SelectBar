import AppKit

/// Keyboard backlight through the private CoreBrightness framework.
/// There is no public API; the class methods were found by enumerating them
/// through the runtime rather than guessed.
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

    // MARK: - Keyboard

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
        // Fade speed 0 with an immediate commit: otherwise the system eases
        // the transition and at a fast beat the light never reaches full.
        _ = keyboard.client.setBrightness(level, fadeSpeed: 0, commit: true,
                                          forKeyboard: keyboard.id)
    }

    /// Blink the keyboard backlight for a given time, then restore it.
    /// The beat is deliberately unhurried: the LEDs take time to come up, and
    /// with fast blinking the light never reaches full.
    static func blink(duration: Duration = .seconds(7),
                      interval: Duration = .milliseconds(500)) async {
        guard !busy else { return }        // a second press does not stack
        busy = true
        defer { busy = false }

        let originalKeyboard = keyboard.map { $0.client.brightnessForKeyboard($0.id) }

        // Counted by time rather than by number of flashes: the duration is
        // given directly and will not drift if the beat changes.
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

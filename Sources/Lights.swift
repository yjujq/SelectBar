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

    /// Whether this machine has a backlight to blink at all. A desktop, or a
    /// keyboard without one, answers no — and then there is nothing worth
    /// watching for notifications for.
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
        guard let keyboard else { return }

        let original = keyboard.client.brightnessForKeyboard(keyboard.id)

        // A backlight already at zero is left alone. There is no telling
        // "the user turned it off" from "the system has not restored it yet
        // after waking", and both make blinking wrong: the value is written
        // with commit, so a blink that ends on zero pins zero as the standing
        // preference and the light stays dead through every later wake.
        guard original > 0 else { return }

        busy = true
        // The restore belongs in a defer, not after the loop. Sleep suspends
        // the task mid-blink, and a plain trailing line simply never ran —
        // leaving the light off for good.
        defer {
            setKeyboard(original)
            busy = false
        }

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
    }
}

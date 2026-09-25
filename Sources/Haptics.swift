import AppKit

/// A tap of the trackpad under the finger.
///
/// `NSHapticFeedbackManager` is the documented way and it is silent here.
/// It obeys "Force Click and haptic feedback" in the trackpad settings, and
/// that switch is off on this machine — read it: `com.apple.trackpad.forceClick`
/// is 0 while the trackpad's own `ActuateDetents` is 1, so the engine works
/// and only the public route to it is shut. Nothing in the API says so; the
/// call returns no value and simply does nothing.
///
/// So the engine is driven directly, through the same private framework
/// TapShortcuts already reads gestures from, bound at runtime rather than
/// linked: every symbol is looked up and a missing one falls back to the
/// public manager rather than failing. That is the whole of the risk of a
/// private interface here — it can go away, and when it does this goes quiet
/// in exactly the way it is quiet now.
@MainActor
enum Haptics {

    /// Which of the engine's patterns to fire.
    ///
    /// Fifteen is the crisp single tap, the one the system uses when
    /// something snaps into place. One through six run from light to firm if
    /// that turns out to be too much or too little.
    private static let pattern: Int32 = 15

    static func tap() {
        if let actuator = engine {
            // A second argument of zero, and two floats of zero: the
            // parameters are undocumented and every known caller passes
            // nothing in them.
            if actuate?(actuator, pattern, 0, 0, 0) == 0 { return }
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Binding

    private typealias CreateDefault = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias GetDeviceID = @convention(c)
        (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenActuator = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias Actuate = @convention(c)
        (UnsafeMutableRawPointer?, Int32, UInt32, Float, Float) -> Int32

    private static var actuate: Actuate?

    /// Opened once and kept. Opening it costs a round trip to the driver, and
    /// the bar can appear many times a minute.
    private static let engine: UnsafeMutableRawPointer? = open()

    private static func open() -> UnsafeMutableRawPointer? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let library = dlopen(path, RTLD_LAZY) else { return nil }
        func bind<T>(_ name: String, _ type: T.Type) -> T? {
            guard let symbol = dlsym(library, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard let createDefault = bind("MTDeviceCreateDefault", CreateDefault.self),
              let deviceID = bind("MTDeviceGetDeviceID", GetDeviceID.self),
              let createActuator = bind("MTActuatorCreateFromDeviceID", CreateActuator.self),
              let openActuator = bind("MTActuatorOpen", OpenActuator.self),
              let actuateFn = bind("MTActuatorActuate", Actuate.self),
              let device = createDefault()
        else { return nil }

        var id: UInt64 = 0
        guard deviceID(device, &id) == 0,
              let actuator = createActuator(id),
              openActuator(actuator) == 0
        else { return nil }

        actuate = actuateFn
        return actuator
    }
}

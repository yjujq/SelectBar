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

    /// The shortest gap between two taps that is worth having.
    ///
    /// A flick along the bar crosses every action in a few milliseconds, and
    /// eight firm taps in that time is a buzz rather than an answer. Sixty
    /// milliseconds is far below a deliberate crossing and far above a flick,
    /// and it also merges the tap for the bar arriving with the one for the
    /// action it arrives under.
    private static let quietFor: TimeInterval = 0.06
    private static var lastTap = Date.distantPast

    static func tap(_ strength: HapticStrength = .strong) {
        let now = Date()
        guard now.timeIntervalSince(lastTap) >= quietFor else { return }
        lastTap = now

        // Twice, if the first is refused: an actuator opened at launch can be
        // stale by the time the bar first appears, and reopening costs a round
        // trip to the driver only on the attempt that failed.
        for attempt in 0...1 {
            if attempt == 1 { reopen() }
            guard let actuator = engine, let actuate else { continue }
            // A second argument of zero, and two floats of zero: the
            // parameters are undocumented and every known caller passes
            // nothing in them.
            if actuate(actuator, strength.pattern, 0, 0, 0) == 0 { return }
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
    private static var opened = false
    private static var engine: UnsafeMutableRawPointer? {
        if !opened { opened = true; handle = open() }
        return handle
    }
    private static var handle: UnsafeMutableRawPointer?

    private static func reopen() {
        handle = open()
    }

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

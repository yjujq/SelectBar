import Foundation
import IOKit
import IOKit.hid

/// Чтение датчика угла крышки.
///
/// Датчик висит на службах AppleSPUHIDDevice и опознаётся парой
/// PrimaryUsagePage = 0x0020 (Sensor), PrimaryUsage = 138 (0x8A).
/// Формат отчёта: байт 0 — report id (должен быть 1), байты 1..2 —
/// угол в градусах, little-endian, значащих 9 бит.
final class LidAngleSensor {
    static let usagePage = 0x0020
    static let usage = 138
    static let reportBufferSize = 4096

    /// Вызывается на каждый корректный отчёт: (угол в градусах, сырые байты).
    var onAngle: ((Double, [UInt8]) -> Void)?

    private var devices: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    deinit {
        for buf in buffers { buf.deallocate() }
    }

    /// Разбудить SPU-драйверы, иначе датчик молчит.
    static func wakeDrivers(reportIntervalMicroseconds: Int = 1000) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDriver"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let props: [(String, Int)] = [
                ("SensorPropertyReportingState", 1),
                ("SensorPropertyPowerState", 1),
                ("ReportInterval", reportIntervalMicroseconds),
            ]
            for (key, value) in props {
                var v = Int32(value)
                if let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
                    IORegistryEntrySetCFProperty(service, key as CFString, num)
                }
            }
            IOObjectRelease(service)
        }
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                        kCFAllocatorDefault, 0) else { return nil }
        let value = ref.takeRetainedValue()
        guard let num = value as? NSNumber else { return nil }
        return num.intValue
    }

    /// Найти и открыть датчик. Возвращает число открытых устройств.
    @discardableResult
    func start() -> Int {
        LidAngleSensor.wakeDrivers()

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDevice"),
                                           &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let context = Unmanaged.passUnretained(self).toOpaque()

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let page = LidAngleSensor.intProperty(service, "PrimaryUsagePage") ?? 0
            let use = LidAngleSensor.intProperty(service, "PrimaryUsage") ?? 0
            guard page == LidAngleSensor.usagePage, use == LidAngleSensor.usage else { continue }

            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: LidAngleSensor.reportBufferSize)
            buffer.initialize(repeating: 0, count: LidAngleSensor.reportBufferSize)
            buffers.append(buffer)

            IOHIDDeviceRegisterInputReportCallback(device, buffer,
                                                   LidAngleSensor.reportBufferSize,
                                                   lidReportCallback, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            devices.append(device)
        }
        return devices.count
    }

    fileprivate func handle(bytes: [UInt8]) {
        guard bytes.count >= 3, bytes[0] == 1 else { return }
        let raw = (UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)) & 0x1FF
        onAngle?(Double(raw), bytes)
    }
}

private let lidReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
    guard let context = context, reportLength >= 3 else { return }
    let sensor = Unmanaged<LidAngleSensor>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
    sensor.handle(bytes: bytes)
}

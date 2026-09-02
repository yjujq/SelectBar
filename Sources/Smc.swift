import Foundation
import IOKit

// Общение с AppleSMC через IOKit. Структура запроса — 80 байт с фиксированной
// раскладкой полей; собираем её как сырой буфер, чтобы не зависеть от того,
// как Swift разложит вложенные структуры.
//
// Раскладка (C):
//   0  UInt32 key
//   4  vers{major,minor,build,reserved} + UInt16 release   -> 4..9
//  12  pLimitData{version,length,cpu,gpu,mem}              -> 12..27
//  28  keyInfo{dataSize, dataType, dataAttributes}         -> 28..39
//  40  result, 41 status, 42 data8, 44 data32
//  48  bytes[32]                                           -> 48..79

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case notPermitted(String)
    case badResult(String, UInt8)
    case unsupportedType(String, String)

    var description: String {
        switch self {
        case .serviceNotFound:
            return "служба AppleSMC не найдена"
        case .openFailed(let kr):
            return String(format: "IOServiceOpen не удался (kr=0x%08x) — нужны права root", UInt32(bitPattern: kr))
        case .callFailed(let kr):
            return String(format: "вызов SMC не удался (kr=0x%08x)", UInt32(bitPattern: kr))
        case .keyNotFound(let k):
            return "ключ SMC \(k) отсутствует"
        case .notPermitted(let k):
            return "SMC запретил запись ключа \(k)"
        case .badResult(let k, let r):
            return "SMC вернул код \(r) на ключ \(k)"
        case .unsupportedType(let k, let t):
            return "ключ \(k) имеет неподдерживаемый тип '\(t)'"
        }
    }
}

func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
    return v
}

func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

struct SMCValue {
    let key: String
    let type: String
    let bytes: [UInt8]
    /// Байт dataAttributes из ответа keyInfo — прошивка сообщает права на ключ.
    let attributes: UInt8

    /// Числовое значение вне зависимости от того, как SMC его хранит.
    var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8 | UInt16(bytes[1])) >> 2)
        case "ui8 ", "si8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case "ui16", "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32", "si32":
            guard bytes.count >= 4 else { return nil }
            var v: UInt32 = 0
            for b in bytes.prefix(4) { v = (v << 8) | UInt32(b) }
            return Double(v)
        default:
            return nil
        }
    }

    var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

final class SMC {
    private var conn: io_connect_t = 0
    private static let structSize = 80
    private static let kernelIndex: UInt32 = 2
    private static let selectorRead: UInt8 = 5
    private static let selectorWrite: UInt8 = 6
    private static let selectorKeyInfo: UInt8 = 9

    /// Диагностика: какие типы user client вообще открываются на AppleSMC.
    static func probeClientTypes(_ report: (UInt32, kern_return_t, String) -> Void) {
        for type in UInt32(0)..<8 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return }
            var c: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, type, &c)
            IOObjectRelease(service)
            var note = "-"
            if kr == KERN_SUCCESS {
                // Проверяем, отвечает ли этот клиент на обычное чтение.
                var input = [UInt8](repeating: 0, count: 80)
                var output = [UInt8](repeating: 0, count: 80)
                var outSize = 80
                input[0] = UInt8(fourCC("F0Ac") & 0xff)
                input[1] = UInt8((fourCC("F0Ac") >> 8) & 0xff)
                input[2] = UInt8((fourCC("F0Ac") >> 16) & 0xff)
                input[3] = UInt8((fourCC("F0Ac") >> 24) & 0xff)
                input[42] = 9
                let rk = IOConnectCallStructMethod(c, 2, &input, 80, &output, &outSize)
                note = rk == KERN_SUCCESS ? "отвечает на keyInfo (result=\(output[40]))"
                                          : String(format: "keyInfo kr=0x%08x", UInt32(bitPattern: rk))
                IOServiceClose(c)
            }
            report(type, kr, note)
        }
    }

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
        conn = c
        openUserClient()
    }

    /// kSMCUserClientOpen. Чтения работают и без него, но записи на Apple Silicon
    /// могут молча отбрасываться, если клиент не был открыт явно.
    private(set) var userClientOpened = false
    private(set) var userClientOpenStatus: kern_return_t = 0

    private func openUserClient() {
        var kr = IOConnectCallScalarMethod(conn, 0, nil, 0, nil, nil)
        if kr != KERN_SUCCESS {
            // Часть прошивок ждёт этот селектор в «структурной» форме.
            var input = [UInt8](repeating: 0, count: SMC.structSize)
            var output = [UInt8](repeating: 0, count: SMC.structSize)
            var outSize = SMC.structSize
            kr = IOConnectCallStructMethod(conn, 0, &input, SMC.structSize, &output, &outSize)
        }
        userClientOpenStatus = kr
        userClientOpened = (kr == KERN_SUCCESS)
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    private func writeU32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buf[offset]     = UInt8(value & 0xff)
        buf[offset + 1] = UInt8((value >> 8) & 0xff)
        buf[offset + 2] = UInt8((value >> 16) & 0xff)
        buf[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func readU32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buf[offset]) | UInt32(buf[offset + 1]) << 8
            | UInt32(buf[offset + 2]) << 16 | UInt32(buf[offset + 3]) << 24
    }

    private func call(_ input: [UInt8], key: String) throws -> [UInt8] {
        var inp = input
        var output = [UInt8](repeating: 0, count: SMC.structSize)
        var outSize = SMC.structSize
        let kr = IOConnectCallStructMethod(conn, SMC.kernelIndex,
                                           &inp, SMC.structSize,
                                           &output, &outSize)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        let result = output[40]
        switch result {
        case 0:    return output
        case 132:  throw SMCError.keyNotFound(key)
        case 133:  throw SMCError.notPermitted(key)
        default:   throw SMCError.badResult(key, result)
        }
    }

    private func keyInfo(_ key: String) throws -> (size: UInt32, type: String, attributes: UInt8) {
        var buf = [UInt8](repeating: 0, count: SMC.structSize)
        writeU32(&buf, 0, fourCC(key))
        buf[42] = SMC.selectorKeyInfo
        let out = try call(buf, key: key)
        return (readU32(out, 28), fourCCString(readU32(out, 32)), out[36])
    }

    /// Есть ли такой ключ вообще.
    func exists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var buf = [UInt8](repeating: 0, count: SMC.structSize)
        writeU32(&buf, 0, fourCC(key))
        writeU32(&buf, 28, info.size)
        buf[42] = SMC.selectorRead
        let out = try call(buf, key: key)
        let n = Int(min(info.size, 32))
        return SMCValue(key: key, type: info.type,
                        bytes: Array(out[48..<(48 + n)]), attributes: info.attributes)
    }

    func readNumber(_ key: String) -> Double? {
        guard let v = try? read(key) else { return nil }
        return v.number
    }

    // MARK: - Перечисление ключей

    /// Сколько всего ключей знает SMC (ключ "#KEY").
    func keyCount() -> Int {
        guard let v = try? read("#KEY"), let n = v.number else { return 0 }
        return Int(n)
    }

    /// Имя ключа по его порядковому номеру (селектор kSMCGetKeyFromIndex).
    func key(at index: Int) -> String? {
        var buf = [UInt8](repeating: 0, count: SMC.structSize)
        buf[42] = 8                                  // kSMCGetKeyFromIndex
        writeU32(&buf, 44, UInt32(index))            // data32 = индекс
        guard let out = try? call(buf, key: "#index") else { return nil }
        return fourCCString(readU32(out, 0))
    }

    /// Записать число в ключ, закодировав его в том типе, который SMC для него объявил.
    func write(_ key: String, number: Double) throws {
        let info = try keyInfo(key)
        var payload = [UInt8](repeating: 0, count: Int(min(info.size, 32)))
        switch info.type {
        case "flt ":
            guard payload.count >= 4 else { throw SMCError.unsupportedType(key, info.type) }
            let raw = Float(number).bitPattern
            payload[0] = UInt8(raw & 0xff)
            payload[1] = UInt8((raw >> 8) & 0xff)
            payload[2] = UInt8((raw >> 16) & 0xff)
            payload[3] = UInt8((raw >> 24) & 0xff)
        case "fpe2":
            guard payload.count >= 2 else { throw SMCError.unsupportedType(key, info.type) }
            let raw = UInt16(max(0, min(16383, number))) << 2
            payload[0] = UInt8(raw >> 8)
            payload[1] = UInt8(raw & 0xff)
        case "ui8 ", "si8 ":
            payload[0] = UInt8(max(0, min(255, number)))
        case "ui16", "si16":
            guard payload.count >= 2 else { throw SMCError.unsupportedType(key, info.type) }
            let raw = UInt16(max(0, min(65535, number)))
            payload[0] = UInt8(raw >> 8)
            payload[1] = UInt8(raw & 0xff)
        case "ui32", "si32":
            guard payload.count >= 4 else { throw SMCError.unsupportedType(key, info.type) }
            var raw = UInt32(max(0, min(4294967295, number)))
            for i in stride(from: 3, through: 0, by: -1) {
                payload[i] = UInt8(raw & 0xff)
                raw >>= 8
            }
        default:
            throw SMCError.unsupportedType(key, info.type)
        }

        var buf = [UInt8](repeating: 0, count: SMC.structSize)
        writeU32(&buf, 0, fourCC(key))
        writeU32(&buf, 28, info.size)
        buf[42] = SMC.selectorWrite
        for (i, b) in payload.enumerated() { buf[48 + i] = b }
        _ = try call(buf, key: key)
    }
}

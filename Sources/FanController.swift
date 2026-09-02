import Foundation

/// Управление вентиляторами через SMC.
///
/// Ключи на каждый вентилятор n: FnAc — текущие обороты, FnMn/FnMx — заводские
/// пределы, FnTg — цель, FnMd — режим (0 = авто, 1 = принудительный).
///
/// На Apple Silicon M1–M4 режим нельзя переключить одной записью: сначала нужно
/// взвести ключ Ftst, выждать, пока системный thermalmonitord отпустит
/// вентиляторы, и лишь затем настойчиво писать FnMd. Одиночная попытка
/// возвращает отказ или молча отбрасывается.
final class FanController {
    struct Fan {
        let index: Int
        let minRPM: Double
        let maxRPM: Double
        let hasModeKey: Bool
        let originalMode: Double?
        let originalTarget: Double?
    }

    enum FanError: Error, CustomStringConvertible {
        case unlockFailed(String)
        case targetRejected(Int)

        var description: String {
            switch self {
            case .unlockFailed(let stage):
                return "не удалось перехватить управление вентиляторами (\(stage))"
            case .targetRejected(let idx):
                return "SMC не принял целевые обороты для вентилятора \(idx)"
            }
        }
    }

    private let smc: SMC
    private(set) var fans: [Fan] = []
    private(set) var forced = false
    private(set) var unlocked = false
    private var originalFtst: Double?

    /// Сколько ждать, пока thermalmonitord отпустит вентиляторы после Ftst.
    var yieldWait: Double = 1.0

    /// Сообщения о ходе разблокировки — чтобы вызывающий мог их показать.
    var onProgress: ((String) -> Void)?

    init(smc: SMC) {
        self.smc = smc
        originalFtst = smc.readNumber("Ftst")
        discover()
    }

    private func discover() {
        for idx in 0..<8 {
            guard let actual = smc.readNumber("F\(idx)Ac") else { continue }
            let mn = smc.readNumber("F\(idx)Mn") ?? max(1000, actual * 0.5)
            let mx = smc.readNumber("F\(idx)Mx") ?? max(mn + 800, actual * 1.5)
            let hasMode = smc.exists("F\(idx)Md")
            fans.append(Fan(index: idx, minRPM: min(mn, mx), maxRPM: max(mn, mx),
                            hasModeKey: hasMode,
                            originalMode: hasMode ? smc.readNumber("F\(idx)Md") : nil,
                            originalTarget: smc.readNumber("F\(idx)Tg")))
        }
    }

    var available: Bool { !fans.isEmpty }

    func currentRPM(_ fan: Fan) -> Double? { smc.readNumber("F\(fan.index)Ac") }
    func targetRPM(_ fan: Fan) -> Double? { smc.readNumber("F\(fan.index)Tg") }

    /// Пишет ключ и перечитывает его, пока значение не закрепится.
    /// Проверка чтением обязательна: SMC умеет вернуть успех и отбросить запись.
    /// Возвращает номер удачной попытки (с единицы) либо nil, если не закрепилось.
    @discardableResult
    private func writeUntilSticks(_ key: String, _ value: Double,
                                  attempts: Int, delayMicros: UInt32) -> Int? {
        let tolerance = 1.0
        for attempt in 0..<attempts {
            try? smc.write(key, number: value)
            if let back = smc.readNumber(key), abs(back - value) < tolerance {
                return attempt + 1
            }
            if attempt < attempts - 1 { usleep(delayMicros) }
        }
        return nil
    }

    /// Перехватить управление у системы. Долгая операция: до нескольких секунд.
    @discardableResult
    func unlockControl() throws -> Bool {
        if unlocked { return true }

        // Путь 1: прямая запись режима — так умеют новые чипы.
        let direct = fans.allSatisfy { fan in
            !fan.hasModeKey || writeUntilSticks("F\(fan.index)Md", 1, attempts: 3, delayMicros: 50_000) != nil
        }
        if direct {
            onProgress?("режим переключён напрямую")
            unlocked = true
            return true
        }

        // Путь 2: через Ftst — так требуют M1–M4.
        guard smc.exists("Ftst") else {
            throw FanError.unlockFailed("прямая запись отклонена, ключа Ftst нет")
        }
        if (smc.readNumber("Ftst") ?? 0) != 1 {
            onProgress?("взвожу Ftst...")
            guard let n = writeUntilSticks("Ftst", 1, attempts: 100, delayMicros: 50_000) else {
                throw FanError.unlockFailed("Ftst не принимает значение")
            }
            onProgress?("Ftst взведён с \(n)-й попытки")
            if yieldWait > 0 {
                onProgress?(String(format: "жду %.1f с, пока thermalmonitord отпустит вентиляторы...", yieldWait))
                usleep(UInt32(yieldWait * 1_000_000))
            }
        }

        onProgress?("перевожу вентиляторы в принудительный режим...")
        var ok = true
        let started = CFAbsoluteTimeGetCurrent()
        for fan in fans where fan.hasModeKey {
            if let n = writeUntilSticks("F\(fan.index)Md", 1, attempts: 300, delayMicros: 100_000) {
                onProgress?("F\(fan.index)Md закрепился с \(n)-й попытки")
            } else {
                ok = false
            }
        }
        guard ok else { throw FanError.unlockFailed("ключ режима не закрепляется") }
        onProgress?(String(format: "управление перехвачено, режим занял %.1f с",
                           CFAbsoluteTimeGetCurrent() - started))
        unlocked = true
        return true
    }

    /// Задать обороты долей 0...1 между нижней и верхней границей.
    @discardableResult
    func setLevel(_ level: Double, floorRPM: Double?, ceilRPM: Double?) throws -> [Double] {
        try unlockControl()
        let clamped = max(0, min(1, level))
        var applied: [Double] = []
        for fan in fans {
            let lo = max(fan.minRPM, floorRPM ?? fan.minRPM)
            let hi = min(fan.maxRPM, ceilRPM ?? fan.maxRPM)
            let rpm = (lo + max(0, hi - lo) * clamped).rounded()
            guard writeUntilSticks("F\(fan.index)Tg", rpm, attempts: 20, delayMicros: 25_000) != nil else {
                throw FanError.targetRejected(fan.index)
            }
            applied.append(rpm)
        }
        forced = true
        return applied
    }

    /// Вернуть вентиляторы системе. Вызывается при простое, перегреве и выходе.
    func release() {
        guard forced || unlocked else { return }
        for fan in fans {
            writeUntilSticks("F\(fan.index)Tg", fan.originalTarget ?? fan.minRPM,
                             attempts: 10, delayMicros: 25_000)
            if fan.hasModeKey {
                writeUntilSticks("F\(fan.index)Md", fan.originalMode ?? 0,
                                 attempts: 20, delayMicros: 50_000)
            }
        }
        // Снять Ftst последним — это и есть возврат управления системе.
        if smc.exists("Ftst") {
            writeUntilSticks("Ftst", originalFtst ?? 0, attempts: 20, delayMicros: 50_000)
        }
        forced = false
        unlocked = false
    }

    /// Безусловный возврат в автоматический режим — на случай, если предыдущий
    /// процесс был убит и не успел прибраться за собой.
    @discardableResult
    func forceAuto() -> Bool {
        var ok = true
        for fan in fans where fan.hasModeKey {
            if writeUntilSticks("F\(fan.index)Md", 0, attempts: 50, delayMicros: 50_000) == nil { ok = false }
        }
        if smc.exists("Ftst") {
            if writeUntilSticks("Ftst", 0, attempts: 50, delayMicros: 50_000) == nil { ok = false }
        }
        forced = false
        unlocked = false
        return ok
    }

    /// Максимум показаний термодатчиков — для страховки от перегрева, пока
    /// системное управление отключено.
    func hottestSensor() -> Double? {
        ["TCDX", "TCHP", "TAOL"].compactMap { smc.readNumber($0) }.filter { $0 > 0 && $0 < 150 }.max()
    }
}

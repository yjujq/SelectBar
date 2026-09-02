import SwiftUI

/// Живые показания датчиков. Всё только на чтение: запись в SMC требует root,
/// и приложение её не делает.
@MainActor
final class SensorReadings: ObservableObject {
    struct FanReading: Identifiable {
        let id: Int
        let rpm: Double
        let minRPM: Double
        let maxRPM: Double
        let forced: Bool
    }

    @Published var fans: [FanReading] = []
    @Published var temperature: Double?
    @Published var lidAngle: Double?
    @Published var available = false

    private var smc: SMC?
    private var controller: FanController?
    private let lid = LidAngleSensor()
    private var timer: Timer?

    /// Датчики опрашиваем только пока настройки открыты — незачем дёргать
    /// контроллер в фоне круглые сутки.
    func start() {
        if smc == nil {
            smc = try? SMC()
            if let smc { controller = FanController(smc: smc) }
            lid.onAngle = { [weak self] angle, _ in
                MainActor.assumeIsolated { self?.lidAngle = angle }
            }
            _ = lid.start()
        }
        available = controller?.available ?? false
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let controller, let smc else { return }
        fans = controller.fans.map { fan in
            FanReading(id: fan.index,
                       rpm: controller.currentRPM(fan) ?? 0,
                       minRPM: fan.minRPM,
                       maxRPM: fan.maxRPM,
                       forced: (smc.readNumber("F\(fan.index)Md") ?? 0) == 1)
        }
        temperature = controller.hottestSensor()
    }
}

struct SensorsTab: View {
    @StateObject private var readings = SensorReadings()

    var body: some View {
        Form {
            Section("Fans") {
                if readings.fans.isEmpty {
                    Text(readings.available ? "Reading…" : "No fans found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(readings.fans) { fan in
                        LabeledContent("Fan \(fan.id)") {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(fan.rpm > 0 ? "\(Int(fan.rpm)) rpm" : "off")
                                    .monospacedDigit()
                                Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if readings.fans.contains(where: \.forced) {
                        Text("Forced mode is active — the system is not controlling the fans.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Sensors") {
                LabeledContent("Hottest") {
                    Text(readings.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
                        .monospacedDigit()
                }
                LabeledContent("Lid angle") {
                    Text(readings.lidAngle.map { String(format: "%.0f°", $0) } ?? "—")
                        .monospacedDigit()
                }
            }

            Section {
                Text("Read-only. Changing fan speed needs root, so it stays behind the menu item that asks for a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { readings.start() }
        .onDisappear { readings.stop() }
    }
}

import Foundation

/// Журнал для разбора сложных случаев. По умолчанию молчит: включается
/// скрытым ключом, чтобы не засорять интерфейс и не писать на диск впустую.
///
///     defaults write local.selectbar debugLog -bool true
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/SelectBar.log"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugLog") }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func write(_ text: String) {
        guard enabled else { return }
        let line = "[\(formatter.string(from: Date()))] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 512_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

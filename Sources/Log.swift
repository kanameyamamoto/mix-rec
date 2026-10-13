import Foundation

/// どこで止まったか後から分かるように、~/Library/Logs/MixRec.log に記録を残す
enum Log {
    private static let lock = NSLock()
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MixRec.log")

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

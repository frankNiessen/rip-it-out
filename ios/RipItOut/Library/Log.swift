import Foundation
import os

/// What the app did, for finding out what went wrong on a phone: shown live in Xcode's
/// console (and Console.app), and kept in a file you can share from Settings.
enum Log {
    private static let logger = Logger(subsystem: "io.github.frankniessen.ripitout", category: "app")
    private static let lock = NSLock()
    private static let maxBytes = 1_000_000

    static var fileURL: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("diagnostics.log")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        lock.lock(); defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) \(message)\n"
        let url = fileURL
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size > UInt64(maxBytes), let data = try? Data(contentsOf: url) {
                // keep the newer half
                try? data.suffix(maxBytes / 2).write(to: url)
                try? h.seekToEnd()
            }
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Milliseconds with a sign, for timing lines.
    static func ms(_ seconds: Double) -> String { String(format: "%+.1f ms", seconds * 1000) }
}

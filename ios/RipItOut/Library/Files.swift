import Foundation

/// File access that works with iCloud Drive and other Files providers (Nextcloud,
/// Dropbox): reads and writes go through NSFileCoordinator, which downloads files
/// that are only in the cloud and tells the provider about new ones.
enum Files {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static let fm = FileManager.default

    /// iCloud Drive keeps files that aren't downloaded as ".<name>.icloud".
    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    static func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholder(for: url).path)
    }

    static func isDownloaded(_ url: URL) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return true } // not in iCloud
        return status == .current || status == .downloaded
    }

    /// Asks iCloud to fetch a file in the background (no-op elsewhere).
    static func startDownload(_ url: URL) {
        try? fm.startDownloadingUbiquitousItem(at: url)
    }

    /// Visible names in a folder, with iCloud placeholders turned back into real names.
    static func list(_ dir: URL) -> [String] {
        var names = Set<String>()
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .immediatelyAvailableMetadataOnly, error: &coordError) { url in
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    names.insert(String(name.dropFirst().dropLast(".icloud".count)))
                } else if !name.hasPrefix(".") {
                    names.insert(name)
                }
            }
        }
        return names.sorted()
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Reads a file, downloading it first if it's only in the cloud. Blocks; call off the main thread.
    static func read(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(Failure.message("Couldn't read \(url.lastPathComponent)"))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// Makes sure a file is on the device (downloads it if needed). Blocks.
    static func download(_ url: URL) throws {
        if isDownloaded(url) { return }
        var coordError: NSError?
        var found = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { url in
            found = fm.fileExists(atPath: url.path)
        }
        if let coordError { throw coordError }
        if !found { throw Failure.message("\(url.lastPathComponent) is missing") }
    }

    static func writeAtomic(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { url in
            result = Result { try data.write(to: url, options: .atomic) }
        }
        if let coordError { throw coordError }
        try result.get()
    }

    /// Replaces `dst` with the local file `src` (moved).
    static func replace(_ dst: URL, with src: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &coordError) { url in
            result = Result {
                if fm.fileExists(atPath: url.path) {
                    _ = try fm.replaceItemAt(url, withItemAt: src)
                } else {
                    try fm.moveItem(at: src, to: url)
                }
            }
        }
        if let coordError { throw coordError }
        try result.get()
    }

    /// Moves a finished local folder into the library in one step, so sync clients and
    /// the desktop app never see half of it.
    static func moveIn(_ src: URL, to dst: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: dst.deletingLastPathComponent(), options: [], error: &coordError) { parent in
            result = Result {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: parent.appendingPathComponent(dst.lastPathComponent))
            }
        }
        if let coordError { throw coordError }
        try result.get()
    }

    static func delete(_ url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { url in
            result = Result { try fm.removeItem(at: url) }
        }
        if let coordError { throw coordError }
        try result.get()
    }

    static func tempDir(_ prefix: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

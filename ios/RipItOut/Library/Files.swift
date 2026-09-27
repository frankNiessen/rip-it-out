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

    /// Set when the library is on a Nextcloud server: files inside its mirror are fetched
    /// from the server when read and uploaded when written.
    nonisolated(unsafe) static var remote: Nextcloud?

    private static func remoteFor(_ url: URL) -> Nextcloud? {
        guard let remote, remote.relative(url) != nil else { return nil }
        return remote
    }

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

    /// Whether a file can be opened without waiting for the network.
    static func isOnDevice(_ url: URL) -> Bool {
        if remoteFor(url) != nil {
            return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
        return isDownloaded(url)
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

    /// nil if the folder's contents can be listed, else what went wrong.
    static func checkReadable(_ dir: URL) -> String? {
        var problem: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .immediatelyAvailableMetadataOnly, error: &coordError) { url in
            do { _ = try fm.contentsOfDirectory(atPath: url.path) } catch { problem = error.localizedDescription }
        }
        return coordError?.localizedDescription ?? problem
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Reads a file, downloading it first if it's only in the cloud. Blocks; call off the main thread.
    static func read(_ url: URL) throws -> Data {
        if let r = remoteFor(url) {
            try r.fetchIfNeeded(url)
            return try Data(contentsOf: url)
        }
        var result: Result<Data, Error> = .failure(Failure.message("Couldn't read \(url.lastPathComponent)"))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// Makes sure a file is on the device (downloads it if needed). Blocks.
    /// (Always coordinated: File Provider apps like Nextcloud don't all report whether a
    /// file is on the device, and a coordinated read of a local file costs nothing.)
    static func download(_ url: URL) throws {
        if let r = remoteFor(url) { return try r.fetchIfNeeded(url) }
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
        try remoteFor(url)?.uploadFile(url)
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
        try remoteFor(dst)?.uploadFile(dst)
    }

    /// Moves a finished local folder into the library in one step, so sync clients and
    /// the desktop app never see half of it.
    /// `upload: false` leaves the upload to the caller (the take upload queue).
    static func moveIn(_ src: URL, to dst: URL, upload: Bool = true) throws {
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
        if upload { try remoteFor(dst)?.uploadFolder(dst) }
    }

    static func delete(_ url: URL) throws {
        try remoteFor(url)?.deleteRemote(url)
        if remoteFor(url) != nil && !fm.fileExists(atPath: url.path) { return } // never fetched
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

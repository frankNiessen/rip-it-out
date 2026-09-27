import Foundation
import Observation

/// The library folder the user picked (in iCloud Drive, Nextcloud, Dropbox or On My
/// iPhone) and the songs in it. The folder is remembered as a bookmark.
@MainActor
@Observable
final class LibraryStore {
    private static let bookmarkKey = "library.bookmark"
    private static let nextcloudKey = "library.nextcloud"

    private(set) var nextcloud: NextcloudAccount?

    private(set) var folder: URL?
    private(set) var songs: [Song] = []
    private(set) var loading = false
    private(set) var pending = 0   // song folders whose manifest is still downloading
    var error: String?

    init() {
        if !restoreNextcloud() { restore() }
    }

    var folderName: String { nextcloud?.libraryPath ?? folder?.lastPathComponent ?? "" }
    var locationLabel: String { nextcloud.map { "Nextcloud: \($0.label)" } ?? folderName }

    // MARK: - Nextcloud

    private func restoreNextcloud() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.nextcloudKey),
              let account = try? JSONDecoder().decode(NextcloudAccount.self, from: data) else { return false }
        guard let password = Keychain.get(account.user + "@" + account.server) else {
            error = "Sign in to Nextcloud again."
            return false
        }
        use(account, password: password)
        return true
    }

    private func use(_ account: NextcloudAccount, password: String) {
        do {
            let remote = try Nextcloud(account: account, password: password)
            Files.remote = remote
            nextcloud = account
            folder = remote.mirror
            songs = []
            Task { await reload() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Checks the account and the folder, then uses it as the library.
    func connect(server: String, user: String, password: String, libraryPath: String) async throws {
        let account = try await Background.run {
            try Nextcloud.connect(server: server, user: user, password: password, libraryPath: libraryPath)
        }
        stopAccess()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        Keychain.set(password, for: account.user + "@" + account.server)
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: Self.nextcloudKey)
        error = nil
        use(account, password: password)
    }

    func disconnect() {
        if let account = nextcloud {
            Keychain.delete(account.user + "@" + account.server)
            if let mirror = Files.remote?.mirror { try? FileManager.default.removeItem(at: mirror) }
        }
        UserDefaults.standard.removeObject(forKey: Self.nextcloudKey)
        Files.remote = nil
        nextcloud = nil
        folder = nil
        songs = []
    }

    struct SongGroup: Identifiable {
        var name: String
        var songs: [Song]
        var id: String { name }
    }

    var groups: [SongGroup] {
        let byGroup = Dictionary(grouping: songs, by: \.group)
        return byGroup.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty } // songs without a group last
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }.map { SongGroup(name: $0, songs: byGroup[$0]!) }
    }

    private(set) var checking = false

    func choose(_ url: URL) {
        // Some providers report false here and still allow access, so only a failed
        // read below counts as no access.
        let accessing = url.startAccessingSecurityScopedResource()
        error = nil
        checking = true
        Task {
            let problem = await Background.get { Files.checkReadable(url) }
            checking = false
            if let problem {
                if accessing { url.stopAccessingSecurityScopedResource() }
                error = "Rip It Out can't read the folder \(url.lastPathComponent) (\(problem)). The app that stores it "
                    + "may not have downloaded it yet: open it once in the Files app, then choose it again."
                return
            }
            if nextcloud != nil { disconnect() }
            if folder != url { stopAccess() }
            do {
                let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            } catch {
                self.error = "The folder works now, but the app can't remember it for next time (\(error.localizedDescription))."
            }
            folder = url
            songs = []
            await reload()
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            error = "The library folder isn't available any more. Choose it again."
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        folder = url
        Task { await reload() }
    }

    private func stopAccess() {
        if nextcloud == nil { folder?.stopAccessingSecurityScopedResource() }
    }

    func reload() async {
        guard let folder, !loading else { return }
        loading = true
        defer { loading = false }
        let remote = Files.remote
        let (found, waiting, problem) = await Background.get { () -> ([Song], Int, String?) in
            var failed = 0
            var problem: String?
            if let remote {
                do { failed = try remote.syncLibrary() } catch { problem = error.localizedDescription }
            }
            let (songs, waiting) = Self.scan(folder)
            return (songs, remote == nil ? waiting : failed, problem)
        }
        guard folder == self.folder else { return } // switched libraries meanwhile
        Uploads.shared.run() // takes that didn't make it up last time
        songs = found
        pending = waiting
        if let problem { error = "Couldn't reach Nextcloud (\(problem)). Showing the songs on this iPhone." }
        else if nextcloud != nil { error = nil }
        if waiting > 0 { // manifests that couldn't be fetched (offline, still syncing): try again
            Task {
                try? await Task.sleep(for: .seconds(10))
                await reload()
            }
        }
    }

    /// Songs in the library. A manifest that isn't on the device yet is fetched through a
    /// coordinated read, which makes iCloud Drive and File Provider apps (Nextcloud,
    /// Dropbox) download it; several at once. Returns the songs and how many manifests
    /// couldn't be read (offline, still syncing), to try again later.
    nonisolated static func scan(_ library: URL) -> ([Song], Int) {
        let dirs = Files.list(library).map { library.appendingPathComponent($0) }
            .filter { Files.isDirectory($0) && Files.exists($0.appendingPathComponent("manifest.json")) }
        var results = [Song?](repeating: nil, count: dirs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
            let dir = dirs[i]
            guard let data = try? Files.read(dir.appendingPathComponent("manifest.json")),
                  let manifest = try? Manifest.decode(data) else { return }
            let takes = Files.list(dir.appendingPathComponent("takes"))
                .filter { Files.exists(dir.appendingPathComponent("takes/\($0)/take.json")) }.count
            lock.lock()
            results[i] = Song(folder: dir, manifest: manifest, takeCount: takes)
            lock.unlock()
        }
        let songs = results.compactMap { $0 }.sorted { ($0.manifest.createdAt ?? "") > ($1.manifest.createdAt ?? "") }
        return (songs, dirs.count - songs.count)
    }

    func song(_ id: String) -> Song? { songs.first { $0.id == id } }

    /// Takes of a song, newest first. Blocks while take.json files download.
    nonisolated static func takes(of song: URL, sync: Bool = true) -> [Take] {
        if sync, let remote = Files.remote, remote.relative(song) != nil {
            try? remote.syncTakes(song.lastPathComponent)
        }
        let root = song.appendingPathComponent("takes")
        var out: [Take] = []
        for name in Files.list(root) {
            let dir = root.appendingPathComponent(name)
            guard let data = try? Files.read(dir.appendingPathComponent("take.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let take = Take(json: json, folder: dir) else { continue }
            out.append(take)
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }
}

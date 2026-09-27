import Foundation
import Security

/// A Nextcloud account the library lives in. The app talks WebDAV to the server and keeps
/// a local copy (the mirror) with the same layout as the library, so everything else reads
/// and writes plain local files. Files (Files.swift) fetches from and uploads to the server
/// for paths inside the mirror.
struct NextcloudAccount: Codable, Equatable {
    var server: String       // https://cloud.example.com (may include a sub path)
    var user: String         // login name, for Basic auth
    var userID: String       // the id in the WebDAV path (can differ from the login name)
    var libraryPath: String  // e.g. "StemLibrary" or "Music/StemLibrary"

    var label: String { "\(libraryPath) on \(URL(string: server)?.host ?? server)" }

    static func normalizedServer(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/index.php") { s.removeLast("/index.php".count) }
        return s
    }

    static func normalizedPath(_ s: String) -> String {
        s.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/")
    }
}

final class Nextcloud: @unchecked Sendable {
    enum Failure: LocalizedError {
        case http(Int, String)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .http(401, _): return "Nextcloud didn't accept the user name or app password."
            case .http(404, let what): return "Not found on the server: \(what)"
            case .http(let code, let what): return "The server answered \(code) for \(what)."
            case .message(let m): return m
            }
        }
    }

    struct Entry {
        var name: String
        var isDirectory: Bool
        var etag: String
        var size: Int
    }

    let account: NextcloudAccount
    private let password: String
    let mirror: URL
    private let session: URLSession
    private let stateLock = NSLock()

    init(account: NextcloudAccount, password: String) throws {
        self.account = account
        self.password = password
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let key = "\(URL(string: account.server)?.host ?? "server")-\(account.userID)-\(account.libraryPath)"
            .replacingOccurrences(of: "/", with: "_")
        var mirror = support.appendingPathComponent("Nextcloud/\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mirror.setResourceValues(values)
        self.mirror = mirror.standardizedFileURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - connecting

    /// Checks the login and the library folder; returns the account with the WebDAV user id.
    static func connect(server: String, user: String, password: String, libraryPath: String) throws -> NextcloudAccount {
        let server = NextcloudAccount.normalizedServer(server)
        let path = NextcloudAccount.normalizedPath(libraryPath)
        guard let url = URL(string: server + "/ocs/v2.php/cloud/user?format=json") else {
            throw Failure.message("That server address isn't valid.")
        }
        var req = URLRequest(url: url)
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue(basicAuth(user, password), forHTTPHeaderField: "Authorization")
        let (data, response) = try send(URLSession.shared, req, what: "the login")
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode, "the login") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = json["ocs"] as? [String: Any], let d = ocs["data"] as? [String: Any],
              let id = d["id"] as? String else {
            throw Failure.message("That doesn't look like a Nextcloud server.")
        }
        let account = NextcloudAccount(server: server, user: user, userID: id, libraryPath: path)
        let nc = try Nextcloud(account: account, password: password)
        let entries = try nc.list("")
        if !entries.contains(where: { $0.isDirectory }) {
            throw Failure.message("The folder \(path) has no song folders.")
        }
        return account
    }

    private static func basicAuth(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    // MARK: - paths

    private var davRoot: String { account.server + "/remote.php/dav/files/" + Self.encode(account.userID) }

    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    /// The server URL of a path relative to the library ("" for the library itself).
    func remoteURL(_ rel: String) -> URL {
        let parts = (account.libraryPath.split(separator: "/") + rel.split(separator: "/")).map { Self.encode(String($0)) }
        return URL(string: davRoot + "/" + parts.joined(separator: "/"))!
    }

    /// The path relative to the library for a file in the mirror, or nil if it's elsewhere.
    func relative(_ local: URL) -> String? {
        let root = mirror.path.hasSuffix("/") ? mirror.path : mirror.path + "/"
        let path = local.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    func local(_ rel: String) -> URL { mirror.appendingPathComponent(rel) }

    // MARK: - HTTP

    private func request(_ method: String, _ rel: String) -> URLRequest {
        var req = URLRequest(url: remoteURL(rel))
        req.httpMethod = method
        req.setValue(Self.basicAuth(account.user, password), forHTTPHeaderField: "Authorization")
        return req
    }

    private static func send(_ session: URLSession, _ req: URLRequest, what: String) throws -> (Data, HTTPURLResponse) {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(Failure.message("No answer from the server"))
        session.dataTask(with: req) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success((data ?? Data(), http))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private func send(_ req: URLRequest, what: String, ok: Set<Int> = [200, 201, 204, 207]) throws -> Data {
        let (data, response) = try Self.send(session, req, what: what)
        guard ok.contains(response.statusCode) else { throw Failure.http(response.statusCode, what) }
        return data
    }

    /// The entries of a folder (without the folder itself); [] if it doesn't exist.
    func list(_ rel: String) throws -> [Entry] {
        var req = request("PROPFIND", rel)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("""
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try Self.send(session, req, what: rel.isEmpty ? account.libraryPath : rel)
        if response.statusCode == 404 { return [] }
        guard response.statusCode == 207 else { throw Failure.http(response.statusCode, rel.isEmpty ? account.libraryPath : rel) }
        let parser = PropfindParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        let own = remoteURL(rel).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return parser.entries.compactMap { e in
            let path = (e.href.removingPercentEncoding ?? e.href)
            let trimmed = (URL(string: e.href)?.path ?? path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed == own { return nil }
            guard let name = trimmed.split(separator: "/").last.map(String.init) else { return nil }
            return Entry(name: name, isDirectory: e.collection, etag: e.etag, size: e.size)
        }
    }

    func download(_ rel: String, to dst: URL) throws {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.downloadTask(with: request("GET", rel)) { tmp, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let tmp else { result = .failure(Failure.http(code, rel)); return }
            result = Result {
                let part = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).part")
                try? fm.removeItem(at: part)
                try fm.moveItem(at: tmp, to: part)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: part, to: dst)
            }
        }.resume()
        done.wait()
        try result.get()
    }

    func upload(_ src: URL, to rel: String) throws {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
        session.uploadTask(with: request("PUT", rel), fromFile: src) { _, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if ![200, 201, 204].contains(code) { result = .failure(Failure.http(code, rel)) }
        }.resume()
        done.wait()
        try result.get()
    }

    func makeFolder(_ rel: String) throws {
        _ = try send(request("MKCOL", rel), what: rel, ok: [201, 405]) // 405: exists already
    }

    func delete(_ rel: String) throws {
        _ = try send(request("DELETE", rel), what: rel, ok: [200, 204, 404])
    }

    // MARK: - mirror

    private var stateURL: URL { mirror.appendingPathComponent(".etags.json") }

    // What was fetched, by etag (folders and take folders), so unchanged things aren't
    // asked for again. Kept in memory, written through to .etags.json.
    private var stateCache: [String: String]?
    /// The song folders' etags from the last library listing.
    private var songEtags: [String: String] = [:]

    private func loadState() -> [String: String] {
        stateLock.lock(); defer { stateLock.unlock() }
        if stateCache == nil {
            stateCache = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))) as? [String: String] ?? [:]
        }
        return stateCache!
    }

    private func updateState(_ change: (inout [String: String]) -> Void) {
        _ = loadState()
        stateLock.lock(); defer { stateLock.unlock() }
        change(&stateCache!)
        if let data = try? JSONSerialization.data(withJSONObject: stateCache!) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func songEtag(_ song: String) -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return songEtags[song]
    }

    /// Brings the song manifests of the mirror up to date. A song folder whose etag didn't
    /// change since the last time is skipped; when a manifest changed (the grid was edited,
    /// the song separated again), its cached tracks are dropped so they're fetched again.
    /// Returns how many songs couldn't be fetched.
    @discardableResult
    func syncLibrary() throws -> Int {
        let fm = FileManager.default
        let remote = try list("").filter { $0.isDirectory && !$0.name.hasPrefix(".") }
        stateLock.lock()
        songEtags = Dictionary(remote.map { ($0.name, $0.etag) }, uniquingKeysWith: { a, _ in a })
        stateLock.unlock()
        var state = loadState()
        let names = Set(remote.map(\.name))
        var removed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: mirror.path)) ?? [] where !name.hasPrefix(".") && !names.contains(name) {
            try? fm.removeItem(at: local(name)) // removed on the server
            removed.append(name)
        }
        let changed = remote.filter { state[$0.name] != $0.etag || !fm.fileExists(atPath: local("\($0.name)/manifest.json").path) }
        var failed = 0
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6
        for entry in changed {
            queue.addOperation {
                do {
                    try self.refreshSong(entry.name)
                    lock.lock(); state[entry.name] = entry.etag; lock.unlock()
                } catch Failure.http(404, _) {
                    lock.lock(); state[entry.name] = entry.etag; lock.unlock() // not a song
                } catch {
                    lock.lock(); failed += 1; lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        let fetched = changed.compactMap { e in state[e.name].map { (e.name, $0) } }
        updateState { s in
            for name in removed { s[name] = nil; s["takes:" + name] = nil }
            for (name, etag) in fetched { s[name] = etag }
        }
        return failed
    }

    private func refreshSong(_ name: String) throws {
        let fm = FileManager.default
        let dir = local(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = dir.appendingPathComponent("manifest.json")
        let fresh = dir.appendingPathComponent(".manifest.json.new")
        try download("\(name)/manifest.json", to: fresh)
        let old = try? Data(contentsOf: manifest)
        if let old, old != (try? Data(contentsOf: fresh)) {
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where file != "takes" && !file.hasPrefix(".") {
                try? fm.removeItem(at: dir.appendingPathComponent(file))
            }
        }
        if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
        try fm.moveItem(at: fresh, to: manifest)
    }

    /// Brings a song's takes in the mirror up to date: take.json of every take on the
    /// server, and takes deleted elsewhere removed. Audio is fetched when a take is played.
    /// Nothing is asked for when the song's folder didn't change since the last time, and
    /// a take's take.json only when its folder changed.
    func syncTakes(_ song: String) throws {
        let fm = FileManager.default
        let songTag = songEtag(song)
        if let songTag, loadState()["takes:" + song] == songTag { return }
        let remote = try list("\(song)/takes").filter { $0.isDirectory && !$0.name.hasPrefix(".") }
        let root = local("\(song)/takes")
        let names = Set(remote.map(\.name))
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasPrefix(".") && !names.contains(name) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        let known = loadState()
        var fetched: [String: String] = [:]
        var complete = true
        for take in remote {
            let key = "take:\(song)/\(take.name)"
            let json = root.appendingPathComponent("\(take.name)/take.json")
            if known[key] == take.etag, fm.fileExists(atPath: json.path) { continue }
            do {
                try download("\(song)/takes/\(take.name)/take.json", to: json)
                fetched[key] = take.etag
            } catch Failure.http(404, _) {
                complete = false // still uploading (take.json comes last): look again next time
            }
        }
        updateState { s in
            for (k, v) in fetched { s[k] = v }
            if complete, let songTag { s["takes:" + song] = songTag }
        }
    }

    /// Fetches a file of the mirror from the server unless it's already here.
    func fetchIfNeeded(_ local: URL) throws {
        guard let rel = relative(local) else { return }
        let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 { return }
        try download(rel, to: local)
    }

    /// Uploads a finished take folder: the audio first, take.json last, so the desktop
    /// never lists a take whose files aren't all there.
    func uploadFolder(_ local: URL) throws {
        guard let rel = relative(local) else { return }
        let parent = (rel as NSString).deletingLastPathComponent
        if !parent.isEmpty { try makeFolder(parent) }
        try makeFolder(rel)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in a == "take.json" ? false : b == "take.json" ? true : a < b }
        for file in files {
            try upload(local.appendingPathComponent(file), to: "\(rel)/\(file)")
        }
    }

    func uploadFile(_ local: URL) throws {
        guard let rel = relative(local) else { return }
        try upload(local, to: rel)
    }

    func deleteRemote(_ local: URL) throws {
        guard let rel = relative(local) else { return }
        try delete(rel)
    }
}

private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Raw { var href = ""; var collection = false; var etag = ""; var size = 0 }
    var entries: [Raw] = []
    private var current: Raw?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "response" { current = Raw() }
        if name == "collection" { current?.collection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": current?.href = value
        case "getetag": current?.etag = value
        case "getcontentlength": current?.size = Int(value) ?? 0
        case "response": if let c = current { entries.append(c) }; current = nil
        default: break
        }
        text = ""
    }
}

enum Keychain {
    private static let service = "RipItOut.nextcloud"

    static func set(_ value: String, for account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

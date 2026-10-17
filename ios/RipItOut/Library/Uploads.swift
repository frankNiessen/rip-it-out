import Foundation
import Observation
import UIKit

/// Takes going up to Nextcloud in the background, and what to say about it.
@MainActor
@Observable
final class Uploads {
    static let shared = Uploads()

    private(set) var text: String?
    private(set) var active = false
    private(set) var failed = false
    /// Takes saved on this iPhone that aren't on the server yet.
    private(set) var pending = 0
    /// Why the last attempt failed, until one works.
    private(set) var lastError: String?

    /// Whether this take is still waiting to go up.
    func isWaiting(_ folder: URL) -> Bool {
        guard let remote = Files.remote, let rel = remote.relative(folder) else { return false }
        return remote.pendingUploads.contains(rel)
    }

    /// Uploads whatever is waiting (after a take, at start, when the app comes back, on
    /// refresh). Safe to call often.
    func run() {
        guard let remote = Files.remote else { pending = 0; return }
        pending = remote.pendingUploads.count
        guard !active, pending > 0 else { return }
        active = true
        failed = false
        let count = pending
        text = count == 1 ? "Uploading the take to Nextcloud…" : "Uploading \(count) takes to Nextcloud…"
        // Leaving the app doesn't stop an upload right away: iOS gives it some more time.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Upload takes") {
            Log.write("upload: iOS wants the app suspended, the rest goes up when it's opened again")
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        Task {
            let result = await Background.get(.utility) { remote.processUploads() }
            active = false
            pending = remote.pendingUploads.count
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            if result.failed > 0 {
                failed = true
                lastError = result.error ?? "no connection"
                text = "Not uploaded yet (\(lastError!)). The take is safe on this iPhone; it's uploaded later."
            } else if result.done == 0 {
                text = nil // nothing went up (a take deleted before its upload)
            } else {
                lastError = nil
                text = result.done == 1 ? "On Nextcloud ✓" : "\(result.done) takes on Nextcloud ✓"
                try? await Task.sleep(for: .seconds(4))
                if !active { text = nil }
            }
        }
    }
}

import Foundation
import Observation

/// Takes going up to Nextcloud in the background, and what to say about it.
@MainActor
@Observable
final class Uploads {
    static let shared = Uploads()

    private(set) var text: String?
    private(set) var active = false
    private(set) var failed = false

    /// Uploads whatever is waiting (after a take, at start, on refresh). Safe to call often.
    func run() {
        guard let remote = Files.remote, !active, !remote.pendingUploads.isEmpty else { return }
        active = true
        failed = false
        let count = remote.pendingUploads.count
        text = count == 1 ? "Uploading the take to Nextcloud…" : "Uploading \(count) takes to Nextcloud…"
        Task {
            let result = await Background.get(.utility) { remote.processUploads() }
            active = false
            if result.failed > 0 {
                failed = true
                text = "Not uploaded yet (\(result.error ?? "no connection")). The take is safe on this iPhone; it's uploaded later."
            } else {
                text = result.done == 1 ? "On Nextcloud ✓" : "\(result.done) takes on Nextcloud ✓"
                try? await Task.sleep(for: .seconds(4))
                if !active { text = nil }
            }
        }
    }
}

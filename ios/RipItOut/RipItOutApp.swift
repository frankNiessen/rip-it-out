import SwiftUI

@main
struct RipItOutApp: App {
    @State private var library = LibraryStore()
    @State private var player: PlayerEngine
    @State private var recorder: Recorder

    init() {
        let player = PlayerEngine()
        _player = State(initialValue: player)
        _recorder = State(initialValue: Recorder(player: player))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .environment(recorder)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.2)
    static let record = Color.red

    static func sectionColor(_ kind: String?) -> Color {
        switch kind {
        case "intro", "outro": return .gray
        case "verse": return .blue
        case "chorus": return .orange
        case "bridge": return .purple
        case "solo", "inst": return .green
        case "break": return .teal
        default: return .indigo
        }
    }

    static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

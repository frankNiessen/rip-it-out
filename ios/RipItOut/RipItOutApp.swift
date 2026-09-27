import SwiftUI

@main
struct RipItOutApp: App {
    @State private var library = LibraryStore()
    @State private var player: PlayerEngine
    @State private var recorder: Recorder
    @Environment(\.scenePhase) private var phase

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
                .preferredColorScheme(.dark)
                .onChange(of: phase) {
                    if phase == .background { Task { await recorder.appInBackground() } }
                    if phase == .active { Task { await recorder.appActive() } }
                }
        }
    }
}

/// The desktop app's look (stemtool/static/index.html): modelled on studio hardware.
/// Matte dark panels and thin rules; lime only where something happens (playhead,
/// count-in, loop, the one main action); numbers in a mono face like a device display.
enum Theme {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    static let bg = hex(0x121416)
    static let panel = hex(0x181b1e)
    static let field = hex(0x1e2226)
    static let line = hex(0x2a2f34)
    static let lineStrong = hex(0x3b4248)
    static let ink = hex(0xe6e9e4)
    static let muted = hex(0x8a928e)
    static let accent = hex(0xc6f432)
    static let onAccent = hex(0x10160a)
    static let lcd = hex(0x0c140a)
    static let lcdBorder = hex(0x253019)
    static let lcdInk = hex(0xbfe83a)
    static let lcdDim = hex(0x5d7431)
    static let lcdOff = hex(0x1b2613)
    static let timeline = hex(0x101214)
    static let record = hex(0xff4d5e)
    static let mute = hex(0xe8a33d) // a lit mute button, like on a console
    static let fail = hex(0xff6b6b)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private static let kindColors: [String: UInt32] = [
        "verse": 0x6f9c86, "chorus": 0xb3c25f, "bridge": 0x9488bf, "inst": 0xbd955f, "solo": 0xbb7a8f,
        "break": 0x555e63, "intro": 0x76848a, "outro": 0x76848a,
    ]
    private static let fallback: [UInt32] = [0xc6f432, 0x3ee88a, 0xc69cf5, 0xffb347, 0x4fd1e8, 0xff7eb6, 0xe8e46f, 0x8fa8ff]

    static func sectionColor(_ s: Manifest.Section) -> Color {
        if let k = s.kind, let c = kindColors[k] { return hex(c) }
        let i = Int((s.label.unicodeScalars.first?.value ?? 65)) - 65
        return hex(fallback[((i % fallback.count) + fallback.count) % fallback.count])
    }

    static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The main action: filled lime (the desktop's .btn).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 20).padding(.vertical, 10)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: .rect(cornerRadius: 3))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Secondary buttons: outlined (.btn.quiet); lime outline and text when on (the Loop button).
struct QuietButtonStyle: ButtonStyle {
    var on = false
    var danger = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1).fixedSize()
            .frame(minHeight: 20)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .foregroundStyle(danger ? Theme.fail : on ? Theme.accent : Theme.ink)
            .background(configuration.isPressed ? Theme.field : .clear, in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? Theme.accent : Theme.lineStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Record: red with a dot that turns into a square while recording (.btn.rec).
struct RecordButtonStyle: ButtonStyle {
    var recording: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: recording ? 1 : 6).frame(width: 11, height: 11)
            configuration.label.lineLimit(1).fixedSize()
        }
        .font(.system(size: 16, weight: .bold))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(Theme.record.opacity(configuration.isPressed ? 0.85 : 1), in: .rect(cornerRadius: 3))
        .opacity(enabled ? 1 : 0.4)
    }
}

/// The M and S buttons of a channel strip: outlined, lit when on (mute amber, solo lime).
struct ChannelButton: View {
    let letter: String
    let on: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(on ? Theme.onAccent : Theme.muted)
                .frame(width: 28, height: 26)
                .background(on ? color : .clear, in: .rect(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(on ? color : Theme.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A value between ‹ and › buttons (the desktop's loop Start and End steppers).
struct Stepper2: View {
    let label: String
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: back) { Text("‹").frame(width: 30, height: 30) }
            Text(label).font(Theme.mono(12)).foregroundStyle(Theme.ink)
            Button(action: forward) { Text("›").frame(width: 30, height: 30) }
        }
        .buttonStyle(.plain)
        .font(Theme.mono(15))
        .foregroundStyle(Theme.muted)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.lineStrong, lineWidth: 1))
    }
}

extension View {
    /// A matte panel with a thin rule around it, like the desktop's decks.
    func panel() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
    }

    /// Forms and lists on the desktop's background instead of the system grey.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.bg)
    }

    func themedNavigation() -> some View {
        toolbarBackground(Theme.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

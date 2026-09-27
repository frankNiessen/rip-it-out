import SwiftUI

/// A song. Practice: the mixer, loops and count-in. Record: the same, plus Record, the
/// camera and the song's takes. The switch at the top keeps the song where it is.
struct SongView: View {
    let songID: String
    var openInRecord = false
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(Recorder.self) private var recorder
    @State private var takes: [Take] = []
    @AppStorage("song.mode") private var modeRaw = Mode.practice.rawValue
    @AppStorage("last.song") private var lastSong = ""

    private var song: Song? { library.song(songID) }
    private var mode: Mode { Mode(rawValue: modeRaw) ?? .practice }

    var body: some View {
        Group {
            if let song {
                page(song)
            } else {
                ContentUnavailableView("Song not found", systemImage: "questionmark.folder")
            }
        }
        .onDisappear {
            player.pause()
            recorder.recordPageOpen = false
        }
    }

    /// Practice | Record, like a segmented control in the desktop's colours.
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach([Mode.practice, .record], id: \.self) { m in
                let on = m == mode
                Button {
                    modeRaw = m.rawValue
                } label: {
                    HStack(spacing: 6) {
                        if m == .record { Circle().fill(on ? Color.white : Theme.record).frame(width: 8, height: 8) }
                        Text(m == .practice ? "Practice" : "Record")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? (m == .practice ? Theme.onAccent : Color.white) : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(on ? (m == .practice ? Theme.accent : Theme.record) : Color.clear, in: .rect(cornerRadius: 3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.panel, in: .rect(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
        .disabled(recorder.state != .idle)
    }

    private func deck(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CounterView().frame(width: 104)
                SongTimeline(song: song)
            }
            .frame(height: 140)
            Caption()
            TransportView(mode: mode)
            Rectangle().fill(Theme.line).frame(height: 1)
            MixerView()
        }
        .panel()
    }

    @ViewBuilder
    private func recordPart(_ song: Song) -> some View {
        if let saved = recorder.lastSaved, saved.folder.deletingLastPathComponent().deletingLastPathComponent() == song.folder {
            NavigationLink(value: Route.take(song: song.id, take: saved.id)) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text("Take saved").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Text("Listen").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .panel()
            }
            .buttonStyle(.plain)
        }
        if let note = recorder.note {
            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        if let upload = Uploads.shared.text {
            HStack(spacing: 8) {
                if Uploads.shared.active { ProgressView().tint(Theme.muted) }
                Text(upload).font(Theme.mono(11)).foregroundStyle(Uploads.shared.failed ? Theme.mute : Theme.muted)
            }
        }
        RecordSetup()
        CameraBox()
        TakesView(song: song, takes: takes)
    }

    private func content(_ song: Song) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modeSwitch
                Text(meta(song)).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1)
                deck(song)
                if mode == .record { recordPart(song) }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .overlay {
            if player.loading {
                Text("Loading tracks…").font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    .padding(14).background(Theme.panel, in: .rect(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
            }
        }
    }

    private func page(_ song: Song) -> some View {
        content(song)
            .navigationTitle(song.title)
            .navigationBarTitleDisplayMode(.inline)
            .themedNavigation()
            .toolbar(.hidden, for: .tabBar)
            .task(id: song.id) { await open(song) }
            .onAppear { applyMode() }
            .onChange(of: modeRaw) { applyMode(entering: true) }
            .onChange(of: recorder.lastSaved?.id) { Task { await loadTakes(song) } }
            .onChange(of: recorder.cameraOn) { Task { await recorder.updateCamera(active: mode == .record) } }
            .onChange(of: recorder.frontCamera) { Task { await recorder.updateCamera(active: mode == .record) } }
            .alert("Rip It Out", isPresented: errorShown) {
                Button("OK") { player.error = nil }
            } message: { Text(player.error ?? "") }
    }

    /// The microphone and the camera only in Record. `entering`: the switch to Record (or
    /// opening the song in it), not coming back to the page.
    private func applyMode(entering: Bool = false) {
        recorder.recordPageOpen = mode == .record
        guard mode == .record else { return }
        if entering {
            player.pause() // Record starts the song itself
            if player.loop != nil { player.setLoop(nil) } // a take is one pass through the song
            recorder.cameraOn = false // video only when you switch it on
        }
        Task { await recorder.updateCamera(active: true) }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })
    }

    private func open(_ song: Song) async {
        lastSong = song.id
        if openInRecord && mode != .record { modeRaw = Mode.record.rawValue } // onChange does the rest
        else if mode == .record { applyMode(entering: true) }
        await player.load(song)
        if player.take != nil { await player.loadTake(nil) } // takes play on their own page
        await loadTakes(song)
    }

    private func meta(_ song: Song) -> String {
        let m = song.manifest
        return [song.artist.isEmpty ? nil : song.artist,
                m.bpm.map { "\(Int($0.rounded())) bpm" },
                "\(Grid(m).beatsPerBar)/4",
                Theme.time(m.durationS)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The takes on this device at once, then whatever changed on the server.
    private func loadTakes(_ song: Song) async {
        let folder = song.folder
        takes = await Task.detached { LibraryStore.takes(of: folder, sync: false) }.value
        takes = await Task.detached { LibraryStore.takes(of: folder) }.value
    }
}

/// The LCD counter, like the desktop's: the bar number, a dot per beat (the "1" in
/// lime), and the section; during a count-in it counts the clicks.
struct CounterView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
            let pos = player.position
            let bpb = max(1, min(player.grid.beatsPerBar, 8))
            let counting = player.countInRemaining > 0
            let now = PlayerEngine.hostNow
            let done = player.countInHosts.filter { $0 <= now + 0.02 }.count
            let p = player.grid.position(at: pos)
            let num: String = counting ? (done == 0 ? "–" : "\((done - 1) % bpb + 1)") : p.map { "\($0.bar)" } ?? "–"
            let beat = counting ? (done == 0 ? 0 : (done - 1) % bpb + 1) : (p?.beat ?? 0)
            let label = counting ? "Count-in" : player.isPlaying ? (player.section(at: pos)?.label ?? "bar") : (pos < 0.05 ? "Ready" : "bar")
            VStack(spacing: 8) {
                Text(num)
                    .font(Theme.mono(40, .semibold))
                    .foregroundStyle(Theme.lcdInk)
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 4) {
                    ForEach(1...bpb, id: \.self) { i in
                        Rectangle()
                            .fill(i <= beat ? (i == 1 ? Theme.lcdInk : Theme.lcdDim) : Theme.lcdOff)
                            .frame(width: 10, height: 4)
                    }
                }
                Text(label).font(Theme.mono(10)).foregroundStyle(Theme.lcdDim).lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(counting ? Theme.hex(0x121d0c) : Theme.lcd, in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.lcdBorder, lineWidth: 1))
        }
    }
}

/// Sections on top, the tempo below (the scale is bpm), the playhead in lime, like the
/// desktop's tempo view. Tap a section to loop it (again to end the loop); tap or drag
/// below to jump.
struct SongTimeline: View {
    let song: Song
    @Environment(PlayerEngine.self) private var player
    @State private var frozenStart: Double?   // the window stays put while you drag
    @State private var pinchBase: Double?
    private let band: CGFloat = 22

    /// The visible part of the song: all of it, or zoomed in around the playhead.
    private func window(_ duration: Double) -> (start: Double, span: Double) {
        if let L = player.loop {
            // a loop fills the view, with a little of what's around it
            let pad = max(1, (L.b - L.a) * 0.08)
            let start = max(0, L.a - pad), end = min(duration, L.b + pad)
            return (start, max(0.5, end - start))
        }
        let zoom = max(1, player.zoom)
        let span = duration / zoom
        guard zoom > 1 else { return (0, duration) }
        let start = frozenStart ?? (player.position - span / 2)
        return (min(max(0, start), duration - span), span)
    }

    var body: some View {
        let duration = max(song.manifest.durationS, 0.1)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                let win = window(duration)
                let x = { (t: Double) in CGFloat((t - win.start) / win.span) * w }
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in drawStatic(ctx, size, win) }
                    ForEach((song.manifest.sections ?? []).filter { $0.end > win.start && $0.start < win.start + win.span }) { s in
                        let looped = player.loop == PlayerEngine.Loop(a: s.start, b: s.end)
                        Text(s.label)
                            .font(Theme.mono(9, .medium))
                            .lineLimit(1)
                            .foregroundStyle(Theme.ink)
                            .padding(.leading, 3)
                            .frame(width: max(1, x(s.end) - x(s.start) - 1), height: band, alignment: .leading)
                            .background(Theme.sectionColor(s).opacity(looped ? 0.9 : 0.45))
                            .clipped()
                            .offset(x: x(s.start))
                    }
                    if let L = player.loop {
                        Rectangle().fill(Theme.accent.opacity(0.10))
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 1.5) }
                            .overlay(alignment: .trailing) { Rectangle().fill(Theme.accent).frame(width: 1.5) }
                            .frame(width: max(2, x(L.b) - x(L.a)), height: h - band)
                            .offset(x: x(L.a), y: band)
                    }
                    if let take = player.take {
                        Rectangle().fill(Theme.record.opacity(0.7))
                            .frame(width: max(2, x(take.startS + take.capturedS) - x(max(0, take.startS))), height: 3)
                            .offset(x: x(max(0, take.startS)), y: h - 3)
                    }
                    Rectangle().fill(Theme.accent).frame(width: 2, height: h)
                        .offset(x: x(player.position) - 1)
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if frozenStart == nil { frozenStart = win.start }
                        // scrub: move the playhead along while stopped
                        if !player.isPlaying && v.startLocation.y >= band {
                            player.seek(min(max(0, win.start + Double(v.location.x / w) * win.span), duration))
                        }
                    }
                    .onEnded { v in
                        let t = min(max(0, win.start + Double(v.location.x / w) * win.span), duration)
                        frozenStart = nil
                        if v.startLocation.y < band, abs(v.translation.width) < 8,
                           let s = song.manifest.sections?.last(where: { $0.start <= t }) {
                            let l = PlayerEngine.Loop(a: s.start, b: s.end)
                            player.setLoop(player.loop == l ? nil : l)
                        } else {
                            player.seek(t)
                        }
                    })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { scale in
                        if pinchBase == nil { pinchBase = player.zoom }
                        player.zoom = min(max(1, (pinchBase ?? 1) * scale), 16)
                    }
                    .onEnded { _ in pinchBase = nil })
            }
        }
        .background(Theme.timeline)
        .clipShape(.rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
    }

    /// The tempo curve (bpm from beat to beat) and bar numbers, for the visible part.
    private func drawStatic(_ ctx: GraphicsContext, _ size: CGSize, _ win: (start: Double, span: Double)) {
        let beats = song.manifest.beats
        guard beats.count > 3 else { return }
        let top = band + 6, bottom = size.height - 16
        var points: [(Double, Double)] = []
        for (a, b) in zip(beats, beats.dropFirst()) where b - a > 0.15 && b - a < 2 {
            points.append((b, 60 / (b - a)))
        }
        guard !points.isEmpty else { return }
        let sorted = points.map(\.1).sorted()
        var lo = sorted[sorted.count / 20], hi = sorted[sorted.count * 19 / 20]
        if hi - lo < 6 { let mid = (hi + lo) / 2; lo = mid - 3; hi = mid + 3 }
        let x = { (t: Double) in CGFloat((t - win.start) / win.span) * size.width }
        let y = { (bpm: Double) in bottom - CGFloat((min(max(bpm, lo), hi) - lo) / (hi - lo)) * (bottom - top) }
        var path = Path()
        var started = false
        for p in points where p.0 >= win.start - 2 && p.0 <= win.start + win.span + 2 {
            let pt = CGPoint(x: x(p.0), y: y(p.1))
            if !started { path.move(to: pt); started = true } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(Theme.muted.opacity(0.8)), lineWidth: 1)

        // bar numbers along the bottom, as many as fit
        let downbeats = song.manifest.downbeats
        guard !downbeats.isEmpty else { return }
        let visible = downbeats.filter { $0 >= win.start && $0 <= win.start + win.span }.count
        let step = Double(max(1, visible)) * 26 / Double(size.width)
        let every = step <= 1 ? 1 : step <= 2 ? 2 : max(4, Int(ceil(step / 4)) * 4)
        for i in stride(from: 0, to: downbeats.count, by: every) where downbeats[i] >= win.start && downbeats[i] <= win.start + win.span {
            let px = x(downbeats[i])
            ctx.fill(Path(CGRect(x: px, y: bottom + 2, width: 1, height: 3)), with: .color(Theme.lineStrong))
            ctx.draw(Text("\(i + 1)").font(Theme.mono(8)).foregroundColor(Theme.muted),
                     at: CGPoint(x: px + 1, y: size.height - 6), anchor: .leading)
        }
    }
}

struct TransportView: View {
    let mode: Mode
    @Environment(PlayerEngine.self) private var player
    @Environment(Recorder.self) private var recorder

    var body: some View {
        @Bindable var player = player
        let recording = recorder.state == .recording
        let busy = recorder.state == .saving || recorder.state == .calibrating
        VStack(alignment: .leading, spacing: 10) {
            // one main action per mode: Play in Practice, Record in Record
            HStack(spacing: 6) {
                if mode == .practice {
                    Button { player.toggle() } label: {
                        Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(recording ? "Stop" : "Record") { Task { await recorder.toggleRecording() } }
                        .buttonStyle(RecordButtonStyle(recording: recording))
                        .disabled(busy)
                }
                Button { player.seek(player.loop?.a ?? 0) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(recording)
                    .accessibilityLabel(player.loop == nil ? "To the start" : "To the start of the loop")
                if mode == .practice {
                    Button { player.toggleSectionLoop() } label: { Label("Loop", systemImage: "repeat") }
                        .buttonStyle(QuietButtonStyle(on: player.loop != nil))
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("Count-in", selection: $player.countInBars) {
                        Text("No count-in").tag(0)
                        Text("Count-in 1 bar").tag(1)
                        Text("Count-in 2 bars").tag(2)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "metronome")
                        Text(player.countInBars == 0 ? "–" : "\(player.countInBars)")
                    }
                }
                .buttonStyle(QuietButtonStyle(on: player.countInBars > 0))
                .disabled(recording)
                .accessibilityLabel("Count-in")
                if mode == .record {
                    Button { recorder.cameraOn.toggle() } label: {
                        Image(systemName: recorder.cameraOn ? "video.fill" : "video.slash")
                    }
                    .buttonStyle(QuietButtonStyle(on: recorder.cameraOn))
                    .disabled(recording)
                    .accessibilityLabel(recorder.cameraOn ? "Video on" : "Video off")
                }
            }
            SectionStrip(locked: recording)
            if recording {
                TimelineView(.animation(minimumInterval: 1 / 20)) { _ in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.record).frame(width: 8)
                        Text(player.countInRemaining > 0 ? "Count-in" : "Recording")
                            .font(Theme.mono(12, .medium)).foregroundStyle(Theme.record)
                        LevelMeter(level: recorder.level)
                    }
                }
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        let db = 20 * log10(max(Double(level), 1e-5))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.field)
                Rectangle().fill(level > 0.95 ? Theme.record : Theme.accent)
                    .frame(width: geo.size.width * min(1, max(0, (db + 60) / 60)))
            }
        }
        .frame(height: 5)
    }
}

/// One channel strip per track, like the desktop's console: name, fader, M and S.
struct MixerView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(player.trackKeys, id: \.self) { key in
                let mine = key == "take"
                let silent = player.effectiveLevel(key) == 0 && player.level(key) > 0
                HStack(spacing: 8) {
                    Text(TrackNames.label(key))
                        .font(.system(size: 14, weight: mine ? .semibold : .regular))
                        .foregroundStyle(mine ? Theme.ink : Theme.muted)
                        .frame(width: 70, alignment: .leading)
                    Fader(value: Binding(get: { Double(player.level(key)) }, set: { player.setLevel(key, Float($0)) }),
                          dimmed: silent)
                    if key != "count" {
                        ChannelButton(letter: "M", on: player.muted.contains(key), color: Theme.mute) { player.toggleMute(key) }
                        ChannelButton(letter: "S", on: player.soloed.contains(key), color: Theme.accent) { player.toggleSolo(key) }
                    } else {
                        Color.clear.frame(width: 60, height: 26)
                    }
                }
            }
        }
    }
}

/// A slim fader like the desktop's: a thin track, filled up to a small knob.
struct Fader: View {
    @Binding var value: Double
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 16
            let x = CGFloat(min(max(value, 0), 1)) * (w - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.lineStrong).frame(height: 3)
                Capsule().fill(dimmed ? Theme.muted : Theme.ink).frame(width: x + knob / 2, height: 3)
                Circle().fill(dimmed ? Theme.muted : Theme.ink).frame(width: knob, height: knob).offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = Double(min(max((g.location.x - knob / 2) / (w - knob), 0), 1))
            })
        }
        .frame(height: 30)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1)
        }
    }
}

/// The song's parts as buttons: the one playing is lit, a tap goes there (or moves the
/// loop there when a loop is on).
struct SectionStrip: View {
    var locked = false
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let sections = player.song?.manifest.sections, !sections.isEmpty {
            TimelineView(.animation(minimumInterval: 1 / 4, paused: !player.isPlaying)) { _ in
                let current = player.section(at: player.position)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sections) { s in
                                let isCurrent = current?.start == s.start
                                let looped = player.loop == PlayerEngine.Loop(a: s.start, b: s.end)
                                Button {
                                    if player.loop != nil { player.setLoop(.init(a: s.start, b: s.end)) } else { player.seek(s.start) }
                                } label: {
                                    HStack(spacing: 5) {
                                        Rectangle().fill(Theme.sectionColor(s)).frame(width: 3, height: 14)
                                        Text(s.label)
                                    }
                                }
                                .buttonStyle(QuietButtonStyle(on: looped || (player.loop == nil && isCurrent)))
                                .id(s.start)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onChange(of: current?.start) { _, start in
                        if let start { withAnimation { proxy.scrollTo(start, anchor: .center) } }
                    }
                }
            }
            .disabled(locked)
        }
    }
}

/// Time on the left, the loop in lime on the right, like the desktop's caption row.
struct Caption: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 4, paused: !player.isPlaying)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(Theme.time(player.position)) / \(Theme.time(player.duration))")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    Stepper2(label: "Bar", back: { player.stepBar(-1) }, forward: { player.stepBar(1) })
                    HStack(spacing: 0) {
                        Button { player.zoom = max(1, player.zoom / 2) } label: { Text("−").frame(width: 30, height: 30) }
                            .disabled(player.zoom <= 1)
                        Button { player.zoom = min(16, player.zoom * 2) } label: { Text("+").frame(width: 30, height: 30) }
                            .disabled(player.zoom >= 16)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.lineStrong, lineWidth: 1))
                    .accessibilityLabel("Zoom")
                }
            }
        }
    }

}

/// The song's takes: tap one to play it with the song (the "My take" fader), Delete
/// throws a bad one away. Timing, level and names are changed on the desktop.
/// What you record with, right where you record: the input, the latency and Calibrate.
struct RecordSetup: View {
    @Environment(Recorder.self) private var recorder

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Input", selection: Binding(get: { recorder.selectedInputUID ?? "" }, set: { recorder.selectInput($0) })) {
                    ForEach(recorder.inputs, id: \.uid) { Text($0.portName).tag($0.uid) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "mic")
                    Text(recorder.inputName)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(recorder.state != .idle)
            Text("\(Int(recorder.latencyMs)) ms").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button(recorder.state == .calibrating ? "Calibrating…" : "Calibrate") { Task { await recorder.calibrate() } }
                .buttonStyle(QuietButtonStyle())
                .disabled(recorder.state != .idle)
        }
        if let note = recorder.calibrationNote, recorder.state == .calibrating || !note.isEmpty {
            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }
}

/// The song's takes, newest first. Each opens the take page (watch and listen).
struct TakesView: View {
    let song: Song
    let takes: [Take]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Takes of this song").font(.system(size: 17, weight: .bold))
                Text("\(takes.count)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 8)
            Rectangle().fill(Theme.line).frame(height: 1)
            if takes.isEmpty {
                Text("No takes yet. Press Record to play along and record yourself.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .padding(.vertical, 12)
            }
            ForEach(takes) { take in
                NavigationLink(value: Route.take(song: song.id, take: take.id)) {
                    HStack(spacing: 12) {
                        Image(systemName: take.hasVideo ? "video" : "waveform")
                            .foregroundStyle(Theme.muted).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(take.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("\(Theme.time(take.startS)) to \(Theme.time(take.startS + take.capturedS))")
                                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

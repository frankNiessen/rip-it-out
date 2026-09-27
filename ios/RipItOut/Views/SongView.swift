import SwiftUI

struct SongView: View {
    let songID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(Recorder.self) private var recorder
    @State private var takes: [Take] = []
    @State private var editing: Take?

    private var song: Song? { library.song(songID) }

    var body: some View {
        Group {
            if let song {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(meta(song)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                CounterView().frame(width: 104)
                                SongTimeline(song: song)
                            }
                            .frame(height: 140)
                            Caption()
                            TransportView()
                            Rectangle().fill(Theme.line).frame(height: 1)
                            MixerView()
                        }
                        .panel()
                        if let note = recorder.note {
                            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        TakesView(takes: $takes, editing: $editing, reload: { await loadTakes(song) })
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
                .navigationTitle(song.title)
                .navigationBarTitleDisplayMode(.inline)
                .themedNavigation()
                .task(id: song.id) {
                    await player.load(song)
                    await loadTakes(song)
                }
                .onChange(of: player.take) { Task { await loadTakes(song) } }
                .sheet(item: $editing) { take in TakeDetailView(song: song, take: take) { await loadTakes(song) } }
                .alert("Rip It Out", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
                    Button("OK") { player.error = nil }
                } message: { Text(player.error ?? "") }
            } else {
                ContentUnavailableView("Song not found", systemImage: "questionmark.folder")
            }
        }
        .onDisappear { player.pause() }
    }

    private func meta(_ song: Song) -> String {
        let m = song.manifest
        return [song.artist.isEmpty ? nil : song.artist,
                m.bpm.map { "\(Int($0.rounded())) bpm" },
                "\(Grid(m).beatsPerBar)/4",
                Theme.time(m.durationS)].compactMap { $0 }.joined(separator: " · ")
    }

    private func loadTakes(_ song: Song) async {
        let folder = song.folder
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
    private let band: CGFloat = 22

    var body: some View {
        let duration = max(song.manifest.durationS, 0.1)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in drawStatic(ctx, size, duration) }
                ForEach(song.manifest.sections ?? []) { s in
                    let looped = player.loop == PlayerEngine.Loop(a: s.start, b: s.end)
                    Text(s.label)
                        .font(Theme.mono(9, .medium))
                        .lineLimit(1)
                        .foregroundStyle(Theme.ink)
                        .padding(.leading, 3)
                        .frame(width: max(1, (s.end - s.start) / duration * w - 1), height: band, alignment: .leading)
                        .background(Theme.sectionColor(s).opacity(looped ? 0.9 : 0.45))
                        .offset(x: s.start / duration * w)
                        .clipped()
                }
                if let L = player.loop {
                    Rectangle().fill(Theme.accent.opacity(0.10))
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 1.5) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.accent).frame(width: 1.5) }
                        .frame(width: max(2, (L.b - L.a) / duration * w), height: h - band)
                        .offset(x: L.a / duration * w, y: band)
                }
                if let take = player.take {
                    Rectangle().fill(Theme.record.opacity(0.7))
                        .frame(width: max(2, min(take.capturedS, duration) / duration * w), height: 3)
                        .offset(x: max(0, take.startS) / duration * w, y: h - 3)
                }
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                    Rectangle().fill(Theme.accent).frame(width: 2, height: h)
                        .offset(x: player.position / duration * w - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                let t = min(max(0, v.location.x / w), 1) * duration
                if v.startLocation.y < band, abs(v.translation.width) < 8,
                   let s = song.manifest.sections?.last(where: { $0.start <= t }) {
                    let l = PlayerEngine.Loop(a: s.start, b: s.end)
                    player.setLoop(player.loop == l ? nil : l)
                } else {
                    player.seek(t)
                }
            })
        }
        .background(Theme.timeline)
        .clipShape(.rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
    }

    /// The tempo curve (bpm from beat to beat) and bar numbers.
    private func drawStatic(_ ctx: GraphicsContext, _ size: CGSize, _ duration: Double) {
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
        let x = { (t: Double) in CGFloat(t / duration) * size.width }
        let y = { (bpm: Double) in bottom - CGFloat((min(max(bpm, lo), hi) - lo) / (hi - lo)) * (bottom - top) }
        var path = Path()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: x(p.0), y: y(p.1))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(Theme.muted.opacity(0.8)), lineWidth: 1)

        // bar numbers along the bottom, as many as fit
        let downbeats = song.manifest.downbeats
        guard !downbeats.isEmpty else { return }
        let every = max(1, Int(ceil(Double(downbeats.count) * 26 / Double(size.width) / 4)) * 4)
        for i in stride(from: 0, to: downbeats.count, by: every) {
            let px = x(downbeats[i])
            ctx.fill(Path(CGRect(x: px, y: bottom + 2, width: 1, height: 3)), with: .color(Theme.lineStrong))
            ctx.draw(Text("\(i + 1)").font(Theme.mono(8)).foregroundColor(Theme.muted),
                     at: CGPoint(x: px + 1, y: size.height - 6), anchor: .leading)
        }
    }
}

struct TransportView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Recorder.self) private var recorder

    var body: some View {
        @Bindable var player = player
        let recording = recorder.state == .recording
        let busy = recorder.state == .saving || recorder.state == .calibrating
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(recording || busy)
                Button("To start") { player.seek(player.loop?.a ?? 0) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(recording)
                Button("Loop") { player.toggleSectionLoop() }
                    .buttonStyle(QuietButtonStyle(on: player.loop != nil))
                    .disabled(recording)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Count-in").font(.system(size: 14)).foregroundStyle(Theme.muted)
                Menu {
                    Picker("Count-in", selection: $player.countInBars) {
                        Text("Off").tag(0)
                        Text("1 bar").tag(1)
                        Text("2 bars").tag(2)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(player.countInBars == 0 ? "Off" : player.countInBars == 1 ? "1 bar" : "2 bars")
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(recording)
                Spacer(minLength: 0)
                Button(recording ? "Stop" : "Record") { Task { await recorder.toggleRecording() } }
                    .buttonStyle(RecordButtonStyle(recording: recording))
                    .disabled(busy)
            }
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
            ForEach(player.trackKeys + (player.countInBars > 0 ? ["count"] : []), id: \.self) { key in
                let mine = key == "take"
                let silent = player.effectiveLevel(key) == 0 && player.level(key) > 0
                HStack(spacing: 8) {
                    Text(TrackNames.label(key))
                        .font(.system(size: 14, weight: mine ? .semibold : .regular))
                        .foregroundStyle(mine ? Theme.ink : Theme.muted)
                        .frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { Double(player.level(key)) }, set: { player.setLevel(key, Float($0)) }), in: 0...1)
                        .tint(silent ? Theme.lineStrong : Theme.ink)
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

/// Time on the left, the loop in lime on the right, like the desktop's caption row.
struct Caption: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 4, paused: !player.isPlaying)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(Theme.time(player.position)) / \(Theme.time(player.duration))")
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    if let L = player.loop {
                        Text("Loop: \(loopLabel(L))").foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                .font(Theme.mono(12))
                if player.loop != nil {
                    HStack(spacing: 8) {
                        Stepper2(label: "Start", back: { player.nudgeLoop(end: false, by: -1) },
                                 forward: { player.nudgeLoop(end: false, by: 1) })
                        Stepper2(label: "End", back: { player.nudgeLoop(end: true, by: -1) },
                                 forward: { player.nudgeLoop(end: true, by: 1) })
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func loopLabel(_ L: PlayerEngine.Loop) -> String {
        let a = Grid.lastLE(player.grid.downbeats, L.a + 0.05) + 1
        let b = Grid.lastLE(player.grid.downbeats, L.b - 0.05) + 1
        let name = player.song?.manifest.sections?.first { abs($0.start - L.a) < 0.05 && abs($0.end - L.b) < 0.05 }?.label
        return "bars \(a) to \(b)" + (name.map { " (\($0))" } ?? "")
    }
}

struct TakesView: View {
    @Binding var takes: [Take]
    @Binding var editing: Take?
    let reload: () async -> Void
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Takes").font(.system(size: 17, weight: .bold))
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
                let selected = player.take?.id == take.id
                HStack(spacing: 12) {
                    Button {
                        Task { await player.loadTake(selected ? nil : take) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected ? Theme.accent : Theme.lineStrong)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(take.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text("\(Theme.time(take.startS)) to \(Theme.time(take.startS + take.capturedS))\(take.hasVideo ? " · video" : "")")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button("Edit") { editing = take }
                        .buttonStyle(QuietButtonStyle())
                }
                .padding(.vertical, 10)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

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
                    VStack(spacing: 18) {
                        CounterView()
                        SongTimeline(song: song)
                        TransportView()
                        if let note = recorder.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                        MixerView()
                        TakesView(takes: $takes, editing: $editing, reload: { await loadTakes(song) })
                    }
                    .padding()
                }
                .overlay { if player.loading { ProgressView("Loading tracks…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
                .navigationTitle(song.title)
                .navigationBarTitleDisplayMode(.inline)
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

    private func loadTakes(_ song: Song) async {
        let folder = song.folder
        takes = await Task.detached { LibraryStore.takes(of: folder) }.value
    }
}

/// The big bar and beat counter; during a count-in it counts the clicks.
struct CounterView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
            let pos = player.position
            let remaining = player.countInRemaining
            HStack(alignment: .firstTextBaseline) {
                if remaining > 0 {
                    let now = PlayerEngine.hostNow
                    let done = player.countInHosts.filter { $0 <= now + 0.02 }.count
                    Text("Count-in").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    Text(done == 0 ? "–" : "\((done - 1) % player.grid.beatsPerBar + 1)")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                } else if let p = player.grid.position(at: pos) {
                    VStack(alignment: .leading) {
                        Text(player.section(at: pos)?.label ?? "").font(.headline).foregroundStyle(.secondary)
                        Text("\(Theme.time(pos)) / \(Theme.time(player.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(p.bar)").font(.system(size: 56, weight: .bold, design: .monospaced))
                    Text(".\(p.beat)").font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(p.down ? Theme.accent : .primary)
                } else {
                    Text("\(Theme.time(pos)) / \(Theme.time(player.duration))").font(.title.monospacedDigit())
                    Spacer()
                }
            }
            .frame(height: 70)
        }
    }
}

/// Sections above, the song's progress below. Tap a section to loop it (tap the loop
/// again to end it); tap or drag the bar to jump.
struct SongTimeline: View {
    let song: Song
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let duration = max(song.manifest.durationS, 0.1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(song.manifest.sections ?? []) { s in
                        let looped = player.loop == PlayerEngine.Loop(a: s.start, b: s.end)
                        Text(s.label)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .frame(width: max(1, (s.end - s.start) / duration * w - 2), height: 26)
                            .background(Theme.sectionColor(s.kind).opacity(looped ? 1 : 0.55), in: .rect(cornerRadius: 4))
                            .overlay { if looped { RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 2) } }
                            .offset(x: s.start / duration * w)
                            .onTapGesture {
                                player.setLoop(looped ? nil : .init(a: s.start, b: s.end))
                            }
                    }
                }
            }
            .frame(height: 26)

            GeometryReader { geo in
                let w = geo.size.width
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        if let L = player.loop {
                            Rectangle().fill(Theme.accent.opacity(0.25))
                                .frame(width: (L.b - L.a) / duration * w)
                                .offset(x: L.a / duration * w)
                        }
                        if let take = player.take {
                            Rectangle().fill(Theme.record.opacity(0.35))
                                .frame(width: min(take.capturedS, duration) / duration * w, height: 4)
                                .offset(x: max(0, take.startS) / duration * w, y: 8)
                        }
                        Rectangle().fill(Theme.accent).frame(width: 2)
                            .offset(x: player.position / duration * w - 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    player.seek(min(max(0, v.location.x / w), 1) * duration)
                })
            }
            .frame(height: 24)
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
        VStack(spacing: 12) {
            HStack(spacing: 28) {
                Button { player.seek(player.loop?.a ?? 0) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(recording)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56))
                }
                .disabled(recording || busy)
                .keyboardShortcut(.space, modifiers: [])
                Button { player.toggleSectionLoop() } label: {
                    Image(systemName: "repeat").foregroundStyle(player.loop != nil ? Theme.accent : .secondary)
                }
                .disabled(recording)
                Button { Task { await recorder.toggleRecording() } } label: {
                    Image(systemName: recording ? "stop.circle.fill" : "record.circle").font(.system(size: 34))
                        .foregroundStyle(Theme.record)
                }
                .disabled(busy)
            }
            .font(.title2)

            Picker("Count-in", selection: $player.countInBars) {
                Text("No count-in").tag(0)
                Text("1 bar").tag(1)
                Text("2 bars").tag(2)
            }
            .pickerStyle(.segmented)
            .disabled(recording)

            if recording {
                TimelineView(.animation(minimumInterval: 1 / 20)) { _ in
                    HStack {
                        Circle().fill(Theme.record).frame(width: 10)
                        Text(player.countInRemaining > 0 ? "Count-in" : "Recording").font(.footnote.bold())
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
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.95 ? .red : .green)
                    .frame(width: geo.size.width * min(1, max(0, (db + 60) / 60)))
            }
        }
        .frame(height: 6)
    }
}

struct MixerView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mix").font(.headline)
            ForEach(player.trackKeys + (player.countInBars > 0 ? ["count"] : []), id: \.self) { key in
                HStack {
                    Text(TrackNames.label(key)).frame(width: 80, alignment: .leading)
                    Slider(value: Binding(get: { Double(player.level(key)) }, set: { player.setLevel(key, Float($0)) }), in: 0...1)
                    Button {
                        player.setLevel(key, player.level(key) > 0 ? 0 : 1)
                    } label: {
                        Image(systemName: player.level(key) > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 28)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

struct TakesView: View {
    @Binding var takes: [Take]
    @Binding var editing: Take?
    let reload: () async -> Void
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Takes").font(.headline)
            if takes.isEmpty {
                Text("No takes yet. Press the record button to play along and record yourself.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(takes) { take in
                let selected = player.take?.id == take.id
                HStack {
                    Button {
                        Task { await player.loadTake(selected ? nil : take) }
                    } label: {
                        HStack {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(take.displayName)
                                Text("\(Theme.time(take.startS)) to \(Theme.time(take.startS + take.capturedS))\(take.hasVideo ? " · video" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { editing = take } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

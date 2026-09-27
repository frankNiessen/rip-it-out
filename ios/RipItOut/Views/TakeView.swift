import SwiftUI

/// Watching and listening back to one take: its video, your take with the band, and
/// the balance between the two. The camera and the microphone stay off here.
struct TakeView: View {
    let songID: String
    let takeID: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(Recorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @State private var take: Take?
    @State private var video = TakeVideo()
    @State private var missing = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var song: Song? { library.song(songID) }

    var body: some View {
        ScrollView {
            if let song, let take {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                        Text("\(take.displayName) · \(Theme.time(take.startS)) to \(Theme.time(take.startS + take.capturedS))")
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    }
                    videoArea(take)
                    VStack(alignment: .leading, spacing: 12) {
                        SongTimeline(song: song).frame(height: 90)
                        Caption()
                        HStack(spacing: 8) {
                            Button(player.isPlaying ? "Pause" : "Play") {
                                if player.isPlaying { player.pause() } else { player.play(countInBars: 0) }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(player.loading || player.take?.id != take.id)
                            Button { player.seek(player.takeStart(take)) } label: { Image(systemName: "backward.end.fill") }
                                .buttonStyle(QuietButtonStyle())
                                .accessibilityLabel("From the start of the take")
                            Spacer(minLength: 0)
                            Button("Take only") { player.setTakeOnly(!player.takeOnly) }
                                .buttonStyle(QuietButtonStyle(on: player.takeOnly))
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        balance
                    }
                    .panel()
                    HStack(spacing: 8) {
                        NavigationLink(value: Route.song(id: song.id, record: true)) {
                            Label("Record again", systemImage: "record.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                        Spacer(minLength: 0)
                        Button("Delete take", role: .destructive) { confirmDelete = true }
                            .buttonStyle(QuietButtonStyle(danger: true))
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.fail) }
                    Text("Timing, level and exports: in Rip It Out on your Mac, where this take shows up too.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .padding(16)
            } else if missing {
                ContentUnavailableView("Take not found", systemImage: "waveform",
                                       description: Text("It may have been deleted on another device."))
                    .padding(.top, 60)
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(Theme.muted)
                    Text("Finding the take…").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .overlay {
            if player.loading {
                Text("Loading the song and your take…").font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    .padding(14).background(Theme.panel, in: .rect(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
            }
        }
        .navigationTitle("Take")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigation()
        .task { await open() }
        .onDisappear {
            player.pause()
            video.stop()
            player.setTakeOnly(false)
            player.clearMutes()
            Task { await player.loadTake(nil) } // the song pages play without it
        }
        .confirmationDialog("Delete this take?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The recording is removed from the library, also on your other devices.")
        }
    }

    @ViewBuilder
    private func videoArea(_ take: Take) -> some View {
        if take.hasVideo {
            ZStack {
                Theme.hex(0x0b0c0d)
                if let p = video.player {
                    VideoPlayerLayer(player: p)
                } else if let problem = video.problem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Theme.muted).padding()
                } else {
                    Text("Loading video…").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .clipShape(.rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
        }
    }

    /// The whole mixer, with My take, and one tap to put your take in place of one
    /// of the band's tracks (it mutes that track).
    private var balance: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stems = player.song?.manifest.stemOrder, !stems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("My take instead of").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    HStack(spacing: 6) {
                        ForEach(stems, id: \.self) { key in
                            Button(TrackNames.label(key)) { player.toggleMute(key) }
                                .buttonStyle(QuietButtonStyle(on: player.muted.contains(key)))
                        }
                    }
                }
            }
            MixerView()
        }
    }

    private func open() async {
        recorder.recordPageOpen = false // no microphone, no camera while watching
        guard let song else { missing = true; return }
        let folder = song.folder, id = takeID
        // The copy on this device first, so the page is there at once; the server only
        // if the take isn't here yet (recorded on another device).
        var found = await Task.detached { LibraryStore.takes(of: folder, sync: false).first { $0.id == id } }.value
        if found == nil {
            found = await Task.detached { LibraryStore.takes(of: folder).first { $0.id == id } }.value
        }
        guard let t = found else { missing = true; return }
        take = t
        await player.load(song)
        if player.take?.id != t.id { await player.loadTake(t) } else { player.seek(player.takeStart(t)) }
        await video.show(t, engine: player)
    }

    private func delete() async {
        guard let take else { return }
        await player.loadTake(nil)
        do {
            try await Task.detached { try TakeStore.delete(take) }.value
            dismiss()
        } catch {
            self.error = "Couldn't delete the take: \(error.localizedDescription)"
        }
    }
}

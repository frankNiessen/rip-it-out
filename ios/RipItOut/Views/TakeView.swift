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
    @State private var exporting: String?
    @State private var shared: SharedFile?

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
                        // the same deck as the song page
                        HStack(spacing: 8) {
                            CounterView().frame(width: 104)
                            SongTimeline(song: song)
                        }
                        .frame(height: 140)
                        Caption()
                        HStack(spacing: 8) {
                            PlayButton(playing: player.isPlaying) {
                                if player.isPlaying { player.pause() } else { player.play(countInBars: 0) }
                            }
                            .disabled(player.loading || player.take?.id != take.id)
                            Button { player.seek(player.takeStart(take)) } label: { Image(systemName: "backward.end.fill") }
                                .buttonStyle(QuietButtonStyle())
                                .accessibilityLabel("From the start of the take")
                            Spacer(minLength: 0)
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        MixerView()
                    }
                    .panel()
                    HStack(spacing: 8) {
                        if let exporting {
                            HStack(spacing: 6) {
                                ProgressView().tint(Theme.muted)
                                Text(exporting).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            }
                        } else {
                            Menu {
                                Button { Task { await share(song, take, video: false) } } label: {
                                    Label("Audio, as you hear it", systemImage: "waveform")
                                }
                                if take.videoPlayable {
                                    Button { Task { await share(song, take, video: true) } } label: {
                                        Label("Video with that sound", systemImage: "video")
                                    }
                                }
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(player.loading || player.take?.id != take.id)
                        }
                        NavigationLink(value: Route.song(id: song.id, record: true)) {
                            Label("Record again", systemImage: "record.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                        Spacer(minLength: 0)
                        Button("Delete take", role: .destructive) { confirmDelete = true }
                            .buttonStyle(QuietButtonStyle(danger: true))
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.fail) }
                    Text("Share mixes the take with the band the way you hear it here. Timing and level: in Rip It Out on your Mac, where this take shows up too.")
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
                Text(player.loadProgress ?? "Loading the song and your take…").font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    .padding(14).background(Theme.panel, in: .rect(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
            }
        }
        .navigationTitle("Take")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigation()
        .toolbar(.hidden, for: .tabBar)
        .task { await open() }
        .onDisappear {
            player.pause()
            video.stop()
            player.setTakeOnly(false)
            player.clearMutes()
            Task { await player.loadTake(nil) } // the song pages play without it
        }
        .sheet(item: $shared) { file in ShareSheet(url: file.url).presentationDetents([.medium, .large]) }
        .confirmationDialog("Delete this take?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The recording is removed from the library, also on your other devices.")
        }
    }

    @ViewBuilder
    private func videoArea(_ take: Take) -> some View {
        if take.hasVideo {
            Group {
                if let p = video.player {
                    VideoPlayerLayer(player: p)
                        .aspectRatio(video.aspect ?? 9 / 16, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .clipShape(.rect(cornerRadius: 3))
                } else if let problem = video.problem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Theme.muted).padding()
                } else {
                    Text("Loading video…").font(Theme.mono(12)).foregroundStyle(Theme.muted).padding(.vertical, 40)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func open() async {
        recorder.recordPageOpen = false // no microphone, no camera while watching
        guard let song else { missing = true; return }
        let folder = song.folder, id = takeID
        // The copy on this device first, so the page is there at once; the server only
        // if the take isn't here yet (recorded on another device).
        var found = await Background.get { LibraryStore.takes(of: folder, sync: false).first { $0.id == id } }
        if found == nil {
            found = await Background.get { LibraryStore.takes(of: folder).first { $0.id == id } }
        }
        guard let t = found else { missing = true; return }
        take = t
        await player.load(song)
        if player.take?.id != t.id { await player.loadTake(t) } else { player.seek(player.takeStart(t)) }
        await video.show(t, engine: player)
    }

    /// Mixes the take's range as you hear it, then opens the share menu.
    private func share(_ song: Song, _ take: Take, video: Bool) async {
        player.pause()
        exporting = "Preparing the audio…"
        error = nil
        defer { exporting = nil }
        let m = song.manifest, sr = Double(m.sampleRate)
        let start = max(0, Int((take.startS * sr).rounded()))
        let end = min(m.numSamples, Int(((take.startS + take.capturedS) * sr).rounded()))
        guard end - start > Int(sr / 2) else { error = "This take doesn't overlap the song."; return }
        let sources = player.mixSources()
        let audioURL = TakeExport.fileURL(song: song.title, take: take.displayName, ext: "m4a")
        do {
            try await Background.run {
                try TakeExport.mixAudio(sources, sampleRate: sr, start: start, frames: end - start, to: audioURL)
            }
            var result = audioURL
            if video, let videoURL = take.videoURL, let vStart = take.videoStartS {
                exporting = "Preparing the video…"
                try await Background.run { try Files.download(videoURL) }
                let out = TakeExport.fileURL(song: song.title, take: take.displayName, ext: "mp4")
                try await TakeExport.video(videoURL, videoStartS: vStart, audio: audioURL,
                                           fromS: Double(start) / sr, durationS: Double(end - start) / sr, to: out)
                result = out
            }
            shared = SharedFile(url: result)
        } catch {
            self.error = "Couldn't prepare the file: \(error.localizedDescription)"
        }
    }

    private func delete() async {
        guard let take else { return }
        await player.loadTake(nil)
        do {
            try await Background.run { try TakeStore.delete(take) }
            dismiss()
        } catch {
            Log.write("delete failed: \(error)")
            self.error = Explain.isNetwork(error)
                ? "Couldn't delete the take on Nextcloud: \(Explain.network(error)) Try again when you're online."
                : "Couldn't delete the take: \(error.localizedDescription)"
        }
    }
}

import SwiftUI

/// The start page: what the app does, one tile each. Practise and Record pick a song
/// first; Takes lists every recording in the library.
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var settings = false
    @AppStorage("last.song") private var lastSong = ""
    @AppStorage("last.mode") private var lastMode = Mode.practice.rawValue

    private var totalTakes: Int { library.songs.reduce(0) { $0 + $1.takeCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Play along with your songs and record yourself.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .padding(.bottom, 4)

                if let song = library.song(lastSong), let mode = Mode(rawValue: lastMode) {
                    NavigationLink(value: Route.song(id: song.id, mode: mode, take: nil)) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.uturn.forward").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Continue \(mode == .practice ? "practising" : "recording")")
                                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                Text(song.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        .panel()
                    }
                    .buttonStyle(.plain)
                }

                Tile(route: .library(.practice), icon: "music.note", title: "Practice",
                     text: "Play along with a song: a fader, mute and solo for every track, loops, count-in and the click.")
                Tile(route: .library(.record), icon: "record.circle", title: "Record",
                     text: "Record yourself along with a song, on video too if you like, then listen back to your take with the band.")
                Tile(route: .takes, icon: "waveform", title: "Takes",
                     text: totalTakes == 0 ? "All your recordings, newest first." : "All your recordings, newest first: \(totalTakes) so far.")

                VStack(alignment: .leading, spacing: 4) {
                    Text(library.locationLabel).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    Text(library.loading && library.songs.isEmpty ? "Fetching the song list…"
                         : "\(library.songs.count) songs in \(library.groups.count) groups")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    if let error = library.error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Theme.fail)
                    }
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .refreshable { await library.reload() }
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigation()
        .toolbar {
            ToolbarItem(placement: .principal) { Logo().fixedSize() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "gearshape").foregroundStyle(Theme.muted) }
                    .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $settings) { SettingsView() }
    }
}

/// A big panel that says what a page is for.
struct Tile: View {
    let route: Route
    let icon: String
    let title: String
    let text: String

    var body: some View {
        NavigationLink(value: route) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(text).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }
            .padding(.vertical, 6)
            .panel()
        }
        .buttonStyle(.plain)
    }
}

/// Every take in the library, newest first, like the desktop's Takes tab. Tap one to
/// listen to it with its song (in Record); Delete removes it.
struct TakeRow: Identifiable {
    var song: Song
    var take: Take
    var id: URL { take.folder }
}

struct TakesOverview: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var rows: [TakeRow] = []
    @State private var loading = false
    @State private var deleting: TakeRow?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.fail).listRowBackground(Theme.bg)
            }
            ForEach(rows) { row in
                NavigationLink(value: Route.song(id: row.song.id, mode: .record, take: row.take.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.song.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(row.take.displayName).font(.system(size: 14)).foregroundStyle(Theme.ink)
                            if row.take.hasVideo {
                                Text("video").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.lineStrong, lineWidth: 1))
                            }
                        }
                        Text("\(Theme.time(row.take.startS)) to \(Theme.time(row.take.startS + row.take.capturedS)) · \(row.take.input)")
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.bg)
                .listRowSeparatorTint(Theme.line)
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = row }
                }
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay {
            if rows.isEmpty && loading {
                Text("Looking for takes…").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            } else if rows.isEmpty {
                ContentUnavailableView("No takes yet", systemImage: "waveform",
                                       description: Text("Open Record, choose a song and press Record. Your takes appear here, and in the desktop app."))
            }
        }
        .navigationTitle("Takes")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigation()
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete this take?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { Task { await delete(d.take) } } }
        } message: {
            Text("The recording is removed from the library, also on your other devices.")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let songs = library.songs
        let found = await withTaskGroup(of: [TakeRow].self) { group in
            for song in songs {
                group.addTask { LibraryStore.takes(of: song.folder).map { TakeRow(song: song, take: $0) } }
            }
            var all: [TakeRow] = []
            for await part in group { all += part }
            return all
        }
        rows = found.sorted { $0.take.createdAt > $1.take.createdAt }
    }

    private func delete(_ take: Take) async {
        if player.take?.id == take.id { await player.loadTake(nil) }
        do {
            try await Task.detached { try TakeStore.delete(take) }.value
            error = nil
            await load()
        } catch {
            self.error = "Couldn't delete the take: \(error.localizedDescription)"
        }
    }
}

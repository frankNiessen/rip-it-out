import SwiftUI

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
                NavigationLink(value: Route.take(song: row.song.id, take: row.take.id)) {
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
                                       description: Text("Open a song, switch to Record and press Record. Your takes appear here, and in the desktop app."))
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

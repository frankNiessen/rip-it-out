import SwiftUI

/// The song page has two modes, switched at the top without leaving the song.
enum Mode: String, Hashable {
    case practice, record
}

enum Route: Hashable {
    case song(id: String, record: Bool = false)
    case take(song: String, take: String)
}

/// Three tabs, always one tap away: Songs (practise and record), Takes (watch and
/// listen back), Settings.
struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @State private var songsPath: [Route] = []
    @State private var takesPath: [Route] = []

    var body: some View {
        if library.folder == nil {
            WelcomeView()
        } else {
            TabView {
                NavigationStack(path: $songsPath) {
                    LibraryView()
                        .navigationDestination(for: Route.self) { destination($0) }
                }
                .tabItem { Label("Songs", systemImage: "music.note.list") }

                NavigationStack(path: $takesPath) {
                    TakesOverview()
                        .navigationDestination(for: Route.self) { destination($0) }
                }
                .tabItem { Label("Takes", systemImage: "waveform") }

                SettingsView(inTab: true)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .toolbarBackground(Theme.panel, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .song(let id, let record): SongView(songID: id, openInRecord: record)
        case .take(let song, let take): TakeView(songID: song, takeID: take)
        }
    }
}

struct WelcomeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var picking = false
    @State private var signingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Logo(size: 30)
            Text("Play along with your songs and record yourself. Connect to the library the desktop app fills: on your Nextcloud, or in a folder in the Files app (iCloud Drive, On My iPhone).")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
            if library.checking {
                Text("Opening the folder…").font(Theme.mono(12)).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Connect to Nextcloud") { signingIn = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Choose a folder in Files") { picking = true }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            if let error = library.error {
                Text(error).foregroundStyle(Theme.fail).font(.system(size: 13))
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.bg)
        .folderPicker(isPresented: $picking)
        .sheet(isPresented: $signingIn) { NextcloudLoginView() }
    }
}

/// The desktop's header mark: a small lime square (the "power LED") and the name.
struct Logo: View {
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: size * 0.45) {
            Rectangle().fill(Theme.accent).frame(width: size * 0.42, height: size * 0.42)
            Text("Rip It Out").font(.system(size: size, weight: .heavy).width(.expanded)).foregroundStyle(Theme.ink)
        }
    }
}

extension View {
    func folderPicker(isPresented: Binding<Bool>) -> some View {
        modifier(FolderPicker(isPresented: isPresented))
    }
}

private struct FolderPicker: ViewModifier {
    @Environment(LibraryStore.self) private var library
    @Binding var isPresented: Bool
    @State private var answered = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
                answered = true
                switch result {
                case .success(let url): library.choose(url)
                case .failure(let error): library.error = "Couldn't open that folder: \(error.localizedDescription)"
                }
            }
            .onChange(of: isPresented) { was, now in
                if now { answered = false; return }
                guard was else { return }
                // When the storage app can't prepare the folder, the picker closes without
                // handing over anything (and without an error). Say so instead of doing nothing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard !answered, !library.checking else { return }
                    library.error = "No folder was opened. If you tapped Open, the storage app couldn't prepare it: "
                        + "open the folder once in the Files app and wait until its songs are listed, then try again."
                }
            }
    }
}

/// The songs, by group. Tap one to practise or record it.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("last.song") private var lastSong = ""
    @State private var search = ""
    @State private var deleting: Song?
    /// Collapsed groups, remembered (like the desktop's folded groups).
    @AppStorage("library.collapsed") private var collapsedRaw = ""
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    private func toggle(_ group: String) {
        var c = collapsed
        if c.contains(group) { c.remove(group) } else { c.insert(group) }
        collapsedRaw = c.sorted().joined(separator: "\n")
    }
    private func matches(_ s: Song) -> Bool {
        search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || s.artist.localizedCaseInsensitiveContains(search)
            || s.group.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        List {
            if search.isEmpty, let last = library.song(lastSong) {
                NavigationLink(value: Route.song(id: last.id)) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.forward").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            Text(last.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                    }
                }
                .listRowBackground(Theme.panel)
            }
            if let error = library.error, !library.songs.isEmpty {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.bg)
            }
            if library.pending > 0 {
                Text("\(library.pending) songs couldn't be fetched yet, trying again…")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.bg)
            }
            ForEach(library.groups) { group in
                let songs = group.songs.filter(matches)
                let open = !search.isEmpty || !collapsed.contains(group.name)
                if !songs.isEmpty {
                    Section {
                        ForEach(open ? songs : []) { song in
                            NavigationLink(value: Route.song(id: song.id)) { SongRow(song: song) }
                                .listRowBackground(Theme.bg)
                                .listRowSeparatorTint(Theme.line)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { deleting = song }
                                }
                        }
                    } header: {
                        Button { withAnimation(.easeOut(duration: 0.15)) { toggle(group.name) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.muted)
                                    .rotationEffect(.degrees(open ? 90 : 0))
                                Text(group.name.isEmpty ? "No group" : group.name)
                                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                                Text("\(songs.count) \(songs.count == 1 ? "song" : "songs")")
                                    .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .textCase(nil)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay {
            if library.songs.isEmpty && !library.loading && library.pending == 0 {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: Text(library.error ?? "Songs you add in Rip It Out on your Mac appear here once \(library.folderName) has synced."))
            } else if library.songs.isEmpty && library.loading {
                ProgressView("Fetching the song list from \(library.folderName)…")
            }
        }
        .searchable(text: $search)
        .refreshable { await library.reload() }
        .confirmationDialog(deleting.map { "Delete \($0.title)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { Task { await library.delete(d) } } }
        } message: {
            if let d = deleting {
                Text(d.takeCount > 0
                     ? "The song and its \(d.takeCount == 1 ? "take" : "\(d.takeCount) takes") are removed from the library, also on your other devices and in the desktop app."
                     : "The song is removed from the library, also on your other devices and in the desktop app.")
            }
        }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigation()
        .toolbar { ToolbarItem(placement: .principal) { Logo().fixedSize() } }
    }
}

struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                if !song.artist.isEmpty {
                    Text(song.artist).font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                if song.takeCount > 0 {
                    Text(song.takeCount == 1 ? "1 take" : "\(song.takeCount) takes")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                }
            }
            Spacer(minLength: 8)
            if let bpm = song.manifest.bpm {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(bpm.rounded()))").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("bpm").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            Text(Theme.time(song.manifest.durationS)).font(Theme.mono(13)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
    }
}

import SwiftUI

struct RootView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if library.folder == nil {
            WelcomeView()
        } else {
            NavigationStack {
                LibraryView()
                    .navigationDestination(for: String.self) { id in SongView(songID: id) }
            }
        }
    }
}

struct WelcomeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var picking = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.path").font(.system(size: 64)).foregroundStyle(Theme.accent)
            Text("Rip It Out").font(.largeTitle.bold())
            Text("Play along with your songs and record yourself. Choose the library folder the desktop app fills, for example in iCloud Drive, Nextcloud or Dropbox.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if library.checking {
                ProgressView("Opening the folder…")
            } else {
                Button("Choose library folder") { picking = true }
                    .buttonStyle(.borderedProminent)
            }
            if let error = library.error {
                Text(error).foregroundStyle(.red).font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .folderPicker(isPresented: $picking)
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

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var search = ""
    @State private var settings = false

    private func matches(_ s: Song) -> Bool {
        search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || s.artist.localizedCaseInsensitiveContains(search)
            || s.group.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        List {
            if library.pending > 0 {
                Label("\(library.pending) songs couldn't be fetched yet, trying again…", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.groups) { group in
                let songs = group.songs.filter(matches)
                if !songs.isEmpty {
                    Section(group.name.isEmpty ? "No group" : group.name) {
                        ForEach(songs) { song in
                            NavigationLink(value: song.id) { SongRow(song: song) }
                        }
                    }
                }
            }
        }
        .overlay {
            if library.songs.isEmpty && !library.loading && library.pending == 0 {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: Text("Songs you add in Rip It Out on your Mac appear here once \(library.folderName) has synced."))
            } else if library.songs.isEmpty && library.loading {
                ProgressView("Fetching the song list from \(library.folderName)…")
            }
        }
        .searchable(text: $search)
        .refreshable { await library.reload() }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $settings) { SettingsView() }
    }
}

struct SongRow: View {
    let song: Song

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.body)
                Text([song.artist, song.manifest.bpm.map { "\(Int($0.rounded())) bpm" }, Theme.time(song.manifest.durationS)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if song.takeCount > 0 {
                Label("\(song.takeCount)", systemImage: "mic.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

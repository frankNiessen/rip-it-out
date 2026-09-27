import SwiftUI

/// Signing in to Nextcloud with an app password (Nextcloud: Settings > Security >
/// Devices & sessions > Create new app password).
struct NextcloudLoginView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nextcloud.server") private var server = ""
    @AppStorage("nextcloud.user") private var user = ""
    @AppStorage("nextcloud.library") private var libraryPath = "StemLibrary"
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("cloud.example.com", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Server") } footer: {
                    Text("The address you open Nextcloud with in the browser.")
                }
                Section {
                    TextField("User name", text: $user)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("App password", text: $password)
                } header: { Text("Account") } footer: {
                    Text("Make an app password in Nextcloud in the browser: your picture > Settings > Security > Devices & sessions > Create new app password. It's stored in this iPhone's keychain.")
                }
                Section {
                    TextField("StemLibrary", text: $libraryPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Library folder") } footer: {
                    Text("The folder with your songs, as it is in Nextcloud, for example StemLibrary or Music/StemLibrary. Songs are downloaded when you open them; takes you record are uploaded to it.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Nextcloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Connect") { Task { await connect() } }
                            .disabled(server.isEmpty || user.isEmpty || password.isEmpty || libraryPath.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await library.connect(server: server, user: user.trimmingCharacters(in: .whitespaces),
                                      password: password.trimmingCharacters(in: .whitespaces), libraryPath: libraryPath)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

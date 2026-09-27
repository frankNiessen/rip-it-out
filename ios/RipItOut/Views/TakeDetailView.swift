import SwiftUI

/// Name, timing and deletion of a take. Timing moves the take against the song (the
/// latency it was placed with), like Timing in the desktop's Record tab.
struct TakeDetailView: View {
    let song: Song
    let take: Take
    let changed: () async -> Void
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var latency = 0.0
    @State private var working = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(take.displayName, text: $name)
                }
                Section {
                    Stepper(value: $latency, in: -500...1000, step: 1) {
                        Text("\(Int(latency)) ms")
                    }
                    Slider(value: $latency, in: max(-500, take.latencyMs - 150)...min(1000, take.latencyMs + 150), step: 1)
                } header: {
                    Text("Timing")
                } footer: {
                    Text("If your playing sits early or late, change this and save: more moves the take earlier. Recorded with \(Int(take.latencyMs)) ms.")
                }
                Section {
                    LabeledContent("Recorded", value: take.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? take.createdAt)
                    LabeledContent("Length", value: Theme.time(take.capturedS))
                    if !take.input.isEmpty { LabeledContent("Input", value: take.input) }
                    if let peak = take.peakDbfs { LabeledContent("Peak", value: "\(peak) dBFS") }
                    if take.hasVideo { Text("This take has a video; watch and export it in Rip It Out on your Mac.").font(.footnote) }
                }
                Section {
                    Button("Delete take", role: .destructive) { confirmDelete = true }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button("Save") { Task { await save() } } }
                }
            }
            .confirmationDialog("Delete this take?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .onAppear {
                name = take.name
                latency = take.latencyMs
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func save() async {
        working = true
        defer { working = false }
        let wasLoaded = player.take?.id == take.id
        if wasLoaded { await player.loadTake(nil) }
        let song = song, take = take, latency = latency, name = name
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try TakeStore.update(song: song, take: take, latencyMs: latency, name: name)
            }.value
            if wasLoaded { await player.loadTake(updated) }
            await changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        if player.take?.id == take.id { await player.loadTake(nil) }
        let take = take
        do {
            try await Task.detached { try TakeStore.delete(take) }.value
            await changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

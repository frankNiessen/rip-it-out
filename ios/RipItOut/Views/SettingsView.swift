import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Recorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        @Bindable var recorder = recorder
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder", value: library.folderName)
                    Button("Choose another folder") { picking = true }
                } header: {
                    Text("Library")
                } footer: {
                    Text("The folder Rip It Out on your Mac writes to. Takes you record here are saved into it and show up on the Mac.")
                }

                Section {
                    LabeledContent("Input", value: recorder.inputName)
                    Stepper(value: $recorder.latencyMs, in: 0...1000, step: 1) {
                        LabeledContent("Latency", value: "\(Int(recorder.latencyMs)) ms")
                    }
                    Button(recorder.state == .calibrating ? "Calibrating…" : "Calibrate") {
                        Task { await recorder.calibrate() }
                    }
                    .disabled(recorder.state != .idle)
                    if let note = recorder.calibrationNote {
                        Text(note).font(.footnote)
                    } else if !recorder.latencyIsMeasured {
                        Text("Estimate reported by iOS; calibrating is more exact.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Calibrate: 20 clicks play. Listen to the first 4, then play a short note or hit with each of the others. Use headphones (wired, or your interface's output): Bluetooth adds a lot of delay, and the speaker ends up in the recording.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .folderPicker(isPresented: $picking)
        }
    }
}

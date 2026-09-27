import SwiftUI

struct SettingsView: View {
    var inTab = false
    @Environment(LibraryStore.self) private var library
    @Environment(Recorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var signingIn = false
    @State private var sharedLog: SharedFile?

    var body: some View {
        @Bindable var recorder = recorder
        NavigationStack {
            Form {
                Section {
                    LabeledContent(library.nextcloud == nil ? "Folder" : "Nextcloud", value: library.nextcloud?.label ?? library.folderName)
                    if library.checking { ProgressView("Opening the folder…") }
                    else {
                        Button(library.nextcloud == nil ? "Connect to Nextcloud" : "Change Nextcloud account") { signingIn = true }
                        Button("Choose a folder in Files") { picking = true }
                        if library.nextcloud != nil {
                            Button("Disconnect from Nextcloud", role: .destructive) { library.disconnect(); dismiss() }
                        }
                    }
                    if let error = library.error { Text(error).font(.footnote).foregroundStyle(Theme.fail) }
                } header: {
                    Text("Library")
                } footer: {
                    Text("The folder Rip It Out on your Mac writes to. Takes you record here are saved into it and show up on the Mac.")
                }

                Section {
                    if recorder.inputs.count > 1 {
                        Picker("Input", selection: Binding(get: { recorder.selectedInputUID ?? "" },
                                                           set: { recorder.selectInput($0) })) {
                            ForEach(recorder.inputs, id: \.uid) { Text($0.portName).tag($0.uid) }
                        }
                    } else {
                        LabeledContent("Input", value: recorder.inputName)
                    }
                    Stepper(value: $recorder.latencyMs, in: -300...1000, step: 1) {
                        LabeledContent("Timing correction", value: "\(Int(recorder.latencyMs)) ms")
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
                    Text("Calibrate: 20 clicks play. Listen to the first 4, then play a short note or hit with each of the others. Use headphones (wired, or your interface's output): Bluetooth adds a lot of delay, and the speaker ends up in the recording. The timing correction is how far the app moves your takes; iOS times the microphone and the output at different points, so on the built-in speaker and microphone it can be a little below zero.")
                }
                Section {
                    Button("Share the diagnostics log") {
                        Log.write("log shared (app \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model))")
                        sharedLog = SharedFile(url: Log.fileURL)
                    }
                    Button("Clear the log", role: .destructive) { Log.clear() }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("What the app did with the audio (timing of each take and calibration, audio changes, uploads). Send it along when something goes wrong.")
                }
            }
            .themedList()
            .themedNavigation()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if !inTab { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
            .folderPicker(isPresented: $picking)
            .sheet(isPresented: $signingIn) { NextcloudLoginView() }
            .sheet(item: $sharedLog) { file in ShareSheet(url: file.url).presentationDetents([.medium, .large]) }
            .onAppear { recorder.refreshInputs() }
        }
    }
}

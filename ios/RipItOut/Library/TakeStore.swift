import AVFoundation

/// Recording and deleting takes in the desktop's layout (stemtool/takes.py).
/// A take is built in a local temporary folder and moved into <song>/takes/<id> in
/// one step, with take.json inside, so the desktop and sync clients never see half of it.
enum TakeStore {
    static func save(song: Song, capture: Capture, captureStartS: Double, latencyMs: Double, input: String) throws -> Take {
        if let e = capture.error { throw e }
        let m = song.manifest
        let now = Date()
        let takes = song.folder.appendingPathComponent("takes")
        var id = TakeJSON.idFormatter().string(from: now)
        while Files.exists(takes.appendingPathComponent(id)) { id += "b" }

        let work = try Files.tempDir("take")
        defer { try? FileManager.default.removeItem(at: work) }

        let src = try AVAudioFile(forReading: capture.url)
        let capturedRate = src.processingFormat.sampleRate
        // The writer closes (and finishes the file) when the closure returns.
        let (frames, peak, rawName): (Int, Float, String) = try {
            let (writer, name) = try AudioIO.openWriter(dir: work, name: "raw", sampleRate: capturedRate)
            let copied = try AudioIO.copyToStereo(src, writer)
            return (copied.frames, copied.peak, name)
        }()
        guard frames >= Int(capturedRate) / 2 else { throw AudioIO.Failure.message("The recording is shorter than half a second") }

        var json = TakeJSON.make(id: id, created: now, input: input, songSampleRate: m.sampleRate,
                                 capturedSampleRate: Int(capturedRate), capturedFrames: frames,
                                 captureStartS: captureStartS, latencyMs: latencyMs, peak: peak)
        let startS = (json["start_s"] as? Double) ?? 0
        let alignedName = try AudioIO.renderAligned(raw: work.appendingPathComponent(rawName), dir: work, name: "my_drums",
                                                    sampleRate: Double(m.sampleRate), total: m.numSamples, startS: startS)
        json["files"] = ["my_drums": alignedName, "raw": rawName]
        try TakeJSON.encode(json).write(to: work.appendingPathComponent("take.json"))

        let final = takes.appendingPathComponent(id)
        try Files.moveIn(work, to: final)
        guard let take = Take(json: json, folder: final) else { throw AudioIO.Failure.message("Couldn't read the new take") }
        return take
    }

    static func delete(_ take: Take) throws {
        try Files.delete(take.folder)
    }
}

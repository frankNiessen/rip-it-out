import AVFoundation

/// Creating, retiming and deleting takes in the desktop's layout (stemtool/takes.py).
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

    /// Changes the timing (the latency used to place the take) and/or the name. A new
    /// latency re-renders the take on the song timeline from raw.flac, like the desktop.
    static func update(song: Song, take: Take, latencyMs: Double?, name: String?) throws -> Take {
        let jsonURL = take.folder.appendingPathComponent("take.json")
        guard var json = try JSONSerialization.jsonObject(with: Files.read(jsonURL)) as? [String: Any] else {
            throw AudioIO.Failure.message("take.json is damaged")
        }
        var rerender = false
        if let latencyMs, TakeJSON.round(latencyMs, 2) != take.latencyMs {
            json["latency_ms"] = TakeJSON.round(latencyMs, 2)
            rerender = true
        }
        if let name { json["name"] = String(name.trimmingCharacters(in: .whitespaces).prefix(120)) }
        TakeJSON.derive(&json)
        if rerender {
            try Files.download(take.rawURL)
            let work = try Files.tempDir("retime")
            defer { try? FileManager.default.removeItem(at: work) }
            let stem = (take.myTakeFile as NSString).deletingPathExtension
            let rendered = try AudioIO.renderAligned(raw: take.rawURL, dir: work, name: stem,
                                                     sampleRate: Double(song.manifest.sampleRate),
                                                     total: song.manifest.numSamples, startS: json["start_s"] as? Double ?? 0)
            if rendered != take.myTakeFile { // this device wrote WAV where the take had FLAC (or back)
                var files = json["files"] as? [String: String] ?? [:]
                files["my_drums"] = rendered
                json["files"] = files
                try? Files.delete(take.myTakeURL)
            }
            try Files.replace(take.folder.appendingPathComponent(rendered), with: work.appendingPathComponent(rendered))
        }
        try Files.writeAtomic(TakeJSON.encode(json), to: jsonURL)
        guard let updated = Take(json: json, folder: take.folder) else { throw AudioIO.Failure.message("Couldn't read the take") }
        return updated
    }

    static func delete(_ take: Take) throws {
        try Files.delete(take.folder)
    }
}

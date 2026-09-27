import Foundation

/// A song's manifest.json, as the desktop engine writes it (stemtool/pipeline.py).
/// The iOS app only reads manifests; the beat grid and sections are edited on the desktop.
struct Manifest: Decodable, Equatable {
    struct Section: Decodable, Equatable, Identifiable {
        var start: Double
        var end: Double
        var label: String
        var kind: String?
        var bar: Int?
        var id: Double { start }
    }

    struct Click: Decodable, Equatable {
        var audio: String
        var midi: String?
    }

    var schema: Int?
    var title: String?
    var artist: String?
    var group: String?
    var createdAt: String?
    var sampleRate: Int
    var numSamples: Int
    var durationS: Double
    var bpm: Double?
    var beatsPerBar: Int?
    var beats: [Double]
    var downbeats: [Double]
    var sections: [Section]?
    var stems: [String: String]
    var click: Click?

    static func decode(_ data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Manifest.self, from: data)
    }

    /// Track keys in mixer order. Songs from Rip It Out 0.2 have drums and no_drums.
    var stemOrder: [String] {
        let known = ["drums", "bass", "vocals", "other", "no_drums"]
        return known.filter { stems[$0] != nil } + stems.keys.filter { !known.contains($0) }.sorted()
    }
}

enum TrackNames {
    static func label(_ key: String) -> String {
        switch key {
        case "drums": return "Drums"
        case "bass": return "Bass"
        case "vocals": return "Vocals"
        case "other": return "Other"
        case "no_drums": return "Music"
        case "click": return "Click"
        case "count": return "Count-in"
        case "take": return "My take"
        default: return key.capitalized
        }
    }
}

/// One song folder in the library.
struct Song: Identifiable, Hashable {
    var folder: URL
    var manifest: Manifest
    var takeCount: Int

    var id: String { folder.lastPathComponent }
    var title: String { manifest.title ?? folder.lastPathComponent }
    var artist: String { manifest.artist ?? "" }
    var group: String { manifest.group ?? "" }

    static func == (a: Song, b: Song) -> Bool { a.folder == b.folder && a.manifest == b.manifest && a.takeCount == b.takeCount }
    func hash(into h: inout Hasher) { h.combine(folder) }
}

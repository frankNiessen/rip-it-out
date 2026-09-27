import Foundation

/// A recorded take, <song>/takes/<id>/take.json (stemtool/takes.py, schema 1).
struct Take: Identifiable, Equatable {
    var id: String
    var createdAt: String
    var name: String
    var input: String
    var sampleRate: Int
    var capturedSampleRate: Int
    var capturedS: Double
    var captureStartS: Double
    var latencyMs: Double
    var peakDbfs: Double?
    var gainDb: Double      // set by Normalize, applied when my_drums is rendered
    var startS: Double
    var myTakeFile: String
    var rawFile: String
    var hasVideo: Bool
    var folder: URL

    var myTakeURL: URL { folder.appendingPathComponent(myTakeFile) }
    var rawURL: URL { folder.appendingPathComponent(rawFile) }

    init?(json: [String: Any], folder: URL) {
        guard let id = json["id"] as? String,
              let sr = json["sample_rate"] as? Int,
              let captured = (json["captured_s"] as? NSNumber)?.doubleValue,
              let captureStart = (json["capture_start_s"] as? NSNumber)?.doubleValue else { return nil }
        let files = json["files"] as? [String: String] ?? [:]
        self.id = id
        self.createdAt = json["created_at"] as? String ?? ""
        self.name = json["name"] as? String ?? ""
        self.input = json["input"] as? String ?? ""
        self.sampleRate = sr
        self.capturedSampleRate = json["captured_sample_rate"] as? Int ?? sr
        self.capturedS = captured
        self.captureStartS = captureStart
        self.latencyMs = (json["latency_ms"] as? NSNumber)?.doubleValue ?? 0
        self.peakDbfs = (json["peak_dbfs"] as? NSNumber)?.doubleValue
        self.gainDb = (json["gain_db"] as? NSNumber)?.doubleValue ?? 0
        self.startS = (json["start_s"] as? NSNumber)?.doubleValue ?? captureStart - latencyMs / 1000
        self.myTakeFile = files["my_drums"] ?? "my_drums.flac"
        self.rawFile = files["raw"] ?? "raw.flac"
        self.hasVideo = json["video"] is [String: Any]
        self.folder = folder
    }

    var createdDate: Date? { TakeJSON.parseDate(createdAt) }

    var displayName: String {
        if !name.isEmpty { return name }
        guard let d = createdDate else { return id }
        return d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// Reading and writing take.json the way the desktop does, keeping fields this app
/// doesn't know (video) untouched.
enum TakeJSON {
    static let schema = 1

    static func idFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }

    /// Like Python's datetime.isoformat(timespec="seconds") in UTC: 2026-09-27T10:00:00+00:00
    static func isoUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return f.string(from: date)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func round(_ x: Double, _ digits: Int) -> Double {
        let p = pow(10.0, Double(digits))
        return (x * p).rounded() / p
    }

    /// The song-time fields (stemtool/takes.py `_derive`). gain_db (a normalized take,
    /// set on the desktop) is kept as it is and applied when my_drums is rendered.
    static func derive(_ take: inout [String: Any]) {
        let captureStart = (take["capture_start_s"] as? NSNumber)?.doubleValue ?? 0
        let latency = (take["latency_ms"] as? NSNumber)?.doubleValue ?? 0
        let start = round(captureStart - latency / 1000, 5)
        take["start_s"] = start
        if var v = take["video"] as? [String: Any] {
            let inCapture = (v["start_in_capture_s"] as? NSNumber)?.doubleValue ?? 0
            let nudge = (v["nudge_ms"] as? NSNumber)?.doubleValue ?? 0
            v["start_s"] = round(start + inCapture + nudge / 1000, 5)
            take["video"] = v
        }
    }

    static func make(id: String, created: Date, input: String, songSampleRate: Int, capturedSampleRate: Int,
                     capturedFrames: Int, captureStartS: Double, latencyMs: Double, peak: Float) -> [String: Any] {
        var take: [String: Any] = [
            "schema": schema,
            "id": id,
            "created_at": isoUTC(created),
            "name": "",
            "input": input,
            "sample_rate": songSampleRate,
            "captured_sample_rate": capturedSampleRate,
            "captured_s": round(Double(capturedFrames) / Double(capturedSampleRate), 3),
            "capture_start_s": round(captureStartS, 5),
            "latency_ms": round(latencyMs, 2),
            "peak_dbfs": round(20 * log10(max(Double(peak), 1e-6)), 1),
            "files": ["my_drums": "my_drums.flac", "raw": "raw.flac"],
            "video": NSNull(),
            "source": "ios",
        ]
        derive(&take)
        return take
    }

    static func encode(_ take: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: take, options: [.prettyPrinted, .sortedKeys])
    }
}

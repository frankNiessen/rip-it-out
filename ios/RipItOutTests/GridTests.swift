import XCTest
@testable import RipItOut

final class GridTests: XCTestCase {
    /// 120 bpm from 0.5 s, 4/4, like the Python tests' generated song.
    private func steady(_ n: Int = 40) -> Grid {
        let beats = (0..<n).map { 0.5 + Double($0) * 0.5 }
        return Grid(beats: beats, downbeats: stride(from: 0, to: n, by: 4).map { beats[$0] }, beatsPerBar: 4, bpm: 120)
    }

    func testLastLE() {
        XCTAssertEqual(Grid.lastLE([1, 2, 3], 0.5), -1)
        XCTAssertEqual(Grid.lastLE([1, 2, 3], 2), 1)
        XCTAssertEqual(Grid.lastLE([1, 2, 3], 9), 2)
        XCTAssertEqual(Grid.lastLE([], 1), -1)
    }

    func testPosition() {
        let g = steady()
        XCTAssertNil(g.position(at: 0.2))
        XCTAssertEqual(g.position(at: 0.5), Grid.Position(bar: 1, beat: 1, down: true))
        XCTAssertEqual(g.position(at: 1.6), Grid.Position(bar: 1, beat: 3, down: false))
        XCTAssertEqual(g.position(at: 2.5), Grid.Position(bar: 2, beat: 1, down: true))
    }

    func testBeatsPerBarEstimate() {
        let beats = (0..<30).map { Double($0) * 0.5 }
        XCTAssertEqual(Grid.estimateBeatsPerBar(beats: beats, downbeats: stride(from: 0, to: 30, by: 3).map { beats[$0] }), 3)
        XCTAssertEqual(Grid.estimateBeatsPerBar(beats: [], downbeats: []), 4)
    }

    func testCountInFromStart() {
        let plan = steady().planStart(from: 0, bars: 1)
        XCTAssertEqual(plan.pos, 0)
        // The first downbeat is at 0.5 s: four clicks lead into it, the first on the "1".
        XCTAssertEqual(plan.clicks.map(\.s), [-1.5, -1.0, -0.5, 0.0])
        XCTAssertEqual(plan.clicks.map(\.down), [true, false, false, false])
    }

    func testCountInSnapsToBarLine() {
        let plan = steady().planStart(from: 3.3, bars: 2)
        XCTAssertEqual(plan.pos, 2.5)             // back to the bar line
        XCTAssertEqual(plan.clicks.count, 8)
        XCTAssertEqual(plan.clicks.last!.s, 2.0, accuracy: 1e-9)  // two bars lead into the bar line
        XCTAssertEqual(plan.clicks.first!.s, -1.5, accuracy: 1e-9)
    }

    func testNoCountIn() {
        let plan = steady().planStart(from: 3.3, bars: 0)
        XCTAssertEqual(plan.pos, 3.3)
        XCTAssertTrue(plan.clicks.isEmpty)
    }

    func testManifestDecoding() throws {
        let json = """
        {"schema": 2, "title": "Test Song", "artist": "Test", "group": "", "sample_rate": 44100,
         "num_samples": 529200, "duration_s": 12, "bpm": 120, "beats_per_bar": 4,
         "beats": [0.5, 1.0], "downbeats": [0.5], "stems": {"other": "other.m4a", "drums": "drums.m4a",
         "vocals": "vocals.m4a", "bass": "bass.m4a"}, "click": {"audio": "click.flac", "midi": "click.mid"},
         "sections": [{"start": 0.0, "end": 12, "label": "Verse", "kind": "verse", "bar": 1}],
         "processing": {"style": "standard"}}
        """
        let m = try Manifest.decode(Data(json.utf8))
        XCTAssertEqual(m.sampleRate, 44100)
        XCTAssertEqual(m.numSamples, 529200)
        XCTAssertEqual(m.stemOrder, ["drums", "bass", "vocals", "other"])
        XCTAssertEqual(m.sections?.first?.label, "Verse")
        XCTAssertEqual(m.click?.audio, "click.flac")
    }

    func testCalibration() {
        let sr = 1000.0
        let clicks = (0..<20).map { 1.0 + Double($0) * 0.5 }
        var mono = [Float](repeating: 0, count: 12000)
        for c in clicks.dropFirst(4) { mono[Int(((c + 0.042) * sr).rounded())] = 0.8 } // everything lands 42 ms late
        guard case .success(let r) = Calibration.analyze(mono: mono, sampleRate: sr, startTime: 0, clicks: clicks, listen: 4) else {
            return XCTFail("no result")
        }
        XCTAssertEqual(r.latencyMs, 42)
        XCTAssertEqual(r.matched, 16)
    }
}

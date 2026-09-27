import AVFoundation
import XCTest
@testable import RipItOut

final class TakeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Files.tempDir("tests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTakeJSONMatchesDesktop() throws {
        var json = TakeJSON.make(id: "2026-09-27_10-00-00", created: Date(timeIntervalSince1970: 1_790_000_000), input: "iPhone Microphone",
                                 songSampleRate: 44100, capturedSampleRate: 48000, capturedFrames: 96000,
                                 captureStartS: 10.123456, latencyMs: 12.345, peak: 0.5)
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertEqual(json["captured_s"] as? Double, 2.0)
        XCTAssertEqual(json["latency_ms"] as? Double, 12.35)
        XCTAssertEqual(json["start_s"] as? Double, 10.11111)
        XCTAssertEqual(json["peak_dbfs"] as? Double, -6.0)
        XCTAssertTrue((json["created_at"] as? String)?.hasSuffix("+00:00") ?? false)

        json["video"] = ["file": "video.mp4", "start_in_capture_s": 0.25, "sync": "audio", "nudge_ms": 10.0]
        TakeJSON.derive(&json)
        XCTAssertEqual((json["video"] as? [String: Any])?["start_s"] as? Double, 10.37111)

        let take = try XCTUnwrap(Take(json: json, folder: dir))
        XCTAssertEqual(take.myTakeFile, "my_drums.flac")
        XCTAssertTrue(take.hasVideo)
        XCTAssertEqual(take.startS, 10.11111)
    }

    private func writeTestFile(_ url: URL, sampleRate: Double, channels: AVAudioChannelCount, frames: Int, value: (Int) -> Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) { for i in 0..<frames { buf.floatChannelData![ch][i] = value(i) } }
        try file.write(from: buf)
    }

    private func readAll(_ url: URL) throws -> (AVAudioPCMBuffer, Double) {
        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return (buf, file.processingFormat.sampleRate)
    }

    func testRawCopyIsStereoFlac() throws {
        let caf = dir.appendingPathComponent("capture.caf")
        try writeTestFile(caf, sampleRate: 48000, channels: 1, frames: 30000) { Float(($0 % 100)) / 200 }
        let name: String = try {
            let (writer, name) = try AudioIO.openWriter(dir: dir, name: "raw", sampleRate: 48000)
            let (frames, peak) = try AudioIO.copyToStereo(try AVAudioFile(forReading: caf), writer)
            XCTAssertEqual(frames, 30000)
            XCTAssertEqual(peak, 0.495, accuracy: 1e-6)
            return name
        }()
        XCTAssertEqual(name, "raw.flac", "this iOS couldn't encode FLAC")
        let (buf, sr) = try readAll(dir.appendingPathComponent(name))
        XCTAssertEqual(sr, 48000)
        XCTAssertEqual(buf.format.channelCount, 2)
        XCTAssertEqual(Int(buf.frameLength), 30000)
        XCTAssertEqual(buf.floatChannelData![1][150], 0.25, accuracy: 1e-4)
    }

    /// The take lands on the song timeline: exactly `total` frames, the capture from
    /// `startS`, silence around it (stemtool/takes.py `_render_aligned`).
    func testRenderAlignedSameRate() throws {
        let raw = dir.appendingPathComponent("raw.caf")
        try writeTestFile(raw, sampleRate: 44100, channels: 2, frames: 44100) { _ in 0.5 }
        let name = try AudioIO.renderAligned(raw: raw, dir: dir, name: "my_drums", sampleRate: 44100, total: 44100 * 3, startS: 1.0)
        let (buf, _) = try readAll(dir.appendingPathComponent(name))
        XCTAssertEqual(Int(buf.frameLength), 44100 * 3)
        let l = buf.floatChannelData![0]
        XCTAssertEqual(l[44099], 0, accuracy: 1e-6)
        XCTAssertEqual(l[44100], 0.5, accuracy: 1e-4)
        XCTAssertEqual(l[88199], 0.5, accuracy: 1e-4)
        XCTAssertEqual(l[88200], 0, accuracy: 1e-6)
    }

    func testRenderAlignedBeforeSongStartAndResampled() throws {
        let raw = dir.appendingPathComponent("raw.caf")
        // 2 s at 48 kHz: silence for the first second, then a constant
        try writeTestFile(raw, sampleRate: 48000, channels: 2, frames: 96000) { $0 < 48000 ? 0 : 0.5 }
        // the capture starts half a second before the song
        let name = try AudioIO.renderAligned(raw: raw, dir: dir, name: "my_drums", sampleRate: 44100, total: 44100 * 4, startS: -0.5)
        let (buf, _) = try readAll(dir.appendingPathComponent(name))
        XCTAssertEqual(Int(buf.frameLength), 44100 * 4)
        let l = buf.floatChannelData![0]
        // the step from 0 to 0.5 was at 1.0 s in the capture, so at 0.5 s in the song
        XCTAssertEqual(l[Int(0.45 * 44100)], 0, accuracy: 1e-3)
        XCTAssertEqual(l[Int(0.55 * 44100)], 0.5, accuracy: 1e-2)
        XCTAssertEqual(l[Int(1.4 * 44100)], 0.5, accuracy: 1e-2)
        XCTAssertEqual(l[Int(1.6 * 44100)], 0, accuracy: 1e-3)
    }

    func testTicks() {
        let buf = Ticks.buffer(clicks: [(0, true), (0.5, false)])
        XCTAssertEqual(Int(buf.frameLength), Int(0.5 * 44100) + Int(0.035 * 44100))
        XCTAssertGreaterThan(buf.floatChannelData![0][10], 0)
    }
}

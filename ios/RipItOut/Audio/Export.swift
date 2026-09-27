import AVFoundation
import SwiftUI

/// Mixing a take with the song the way you hear it, for sharing: an AAC file, and an MP4
/// with the take's video when it has one (like the desktop's Export audio and video).
enum TakeExport {
    struct Source {
        var url: URL
        var gain: Float
    }

    static let chunk: AVAudioFrameCount = 32768

    /// Mixes `frames` frames from `start` of every source into an AAC file. Loud mixes are
    /// brought down to just below full scale, like the desktop's export.
    static func mixAudio(_ sources: [Source], sampleRate: Double, start: Int, frames: Int, to url: URL) throws {
        let format = AudioIO.stereo(sampleRate)
        let files = try sources.filter { $0.gain > 0 }.map { (try AVAudioFile(forReading: $0.url), $0.gain) }
        guard let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioIO.Failure.message("Out of memory")
        }

        /// Fills `mix` with the mix of frames [pos, pos + n).
        func render(_ pos: Int, _ n: Int) throws {
            for ch in 0..<2 { mix.floatChannelData![ch].update(repeating: 0, count: n) }
            mix.frameLength = AVAudioFrameCount(n)
            for (file, gain) in files {
                guard AVAudioFramePosition(pos) < file.length else { continue }
                file.framePosition = AVAudioFramePosition(pos)
                let want = AVAudioFrameCount(min(Int64(n), file.length - Int64(pos)))
                try file.read(into: part, frameCount: want)
                let got = Int(part.frameLength)
                let channels = Int(part.format.channelCount)
                for ch in 0..<2 {
                    let src = part.floatChannelData![min(ch, channels - 1)]
                    let dst = mix.floatChannelData![ch]
                    for i in 0..<got { dst[i] += src[i] * gain }
                }
            }
        }

        var peak: Float = 0
        var pos = start
        while pos < start + frames {
            let n = min(Int(chunk), start + frames - pos)
            try render(pos, n)
            for ch in 0..<2 {
                let d = mix.floatChannelData![ch]
                for i in 0..<n { peak = max(peak, abs(d[i])) }
            }
            pos += n
        }
        let scale: Float = peak > 0.99 ? 0.99 / peak : 1

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        pos = start
        while pos < start + frames {
            let n = min(Int(chunk), start + frames - pos)
            try render(pos, n)
            if scale != 1 {
                for ch in 0..<2 {
                    let d = mix.floatChannelData![ch]
                    for i in 0..<n { d[i] *= scale }
                }
            }
            try out.write(from: mix)
            pos += n
        }
    }

    /// The take's video over song time [fromS, fromS + durationS), with `audio` as its sound.
    static func video(_ videoURL: URL, videoStartS: Double, audio: URL, fromS: Double, durationS: Double, to url: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audio)
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioIO.Failure.message("The video can't be read.")
        }
        let ts: CMTimeScale = 600
        let videoDuration = try await videoAsset.load(.duration).seconds
        // song time t is video time t - videoStartS; the export's time 0 is song time fromS
        let vFrom = max(0, fromS - videoStartS)
        let vTo = min(videoDuration, fromS + durationS - videoStartS)
        if vTo > vFrom {
            try cv.insertTimeRange(CMTimeRange(start: CMTime(seconds: vFrom, preferredTimescale: ts),
                                               end: CMTime(seconds: vTo, preferredTimescale: ts)),
                                   of: vTrack, at: CMTime(seconds: max(0, videoStartS - fromS), preferredTimescale: ts))
            cv.preferredTransform = try await vTrack.load(.preferredTransform)
        }
        let audioDuration = try await audioAsset.load(.duration)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: aTrack, at: .zero)

        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AudioIO.Failure.message("The video can't be exported on this device.")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        if session.status != .completed {
            throw session.error ?? AudioIO.Failure.message("The video export failed.")
        }
    }

    /// A file name people recognise: "Song - Take.m4a".
    static func fileURL(song: String, take: String, ext: String) -> URL {
        let clean = "\(song) - \(take)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(clean).\(ext)")
    }
}

/// A file to hand to the share menu.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The iOS share menu for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

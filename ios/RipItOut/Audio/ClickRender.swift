import AVFoundation

/// The click for a slowed-down song: the same ticks as the normal click, not stretched,
/// on the beats at their slowed times. Written in pieces, so a long song at half speed
/// never needs one big buffer.
enum ClickRender {
    static func render(beats: [Double], downbeats: [Double], rate: Double, to url: URL) throws {
        let sr = Ticks.sampleRate
        let format = AudioIO.stereo(sr)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let tickLen = Int(0.035 * sr)
        let starts = beats.map { Int((($0 / rate) * sr).rounded()) }
        let downs = beats.map { b -> Bool in
            let i = Grid.lastLE(downbeats, b + 0.03)
            return i >= 0 && abs(downbeats[i] - b) < 0.03
        }
        let total = (starts.last ?? 0) + tickLen
        let chunk = 65536
        var first = 0 // the first beat whose tick may still reach into this chunk
        var at = 0
        while at < total {
            let n = min(chunk, total - at)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let l = buf.floatChannelData![0]
            l.update(repeating: 0, count: n)
            while first < starts.count, starts[first] + tickLen <= at { first += 1 }
            var i = first
            while i < starts.count, starts[i] < at + n {
                let freq = downs[i] ? 1760.0 : 1100.0
                for k in 0..<tickLen {
                    let frame = starts[i] + k - at
                    if frame >= 0 && frame < n {
                        let t = Double(k) / sr
                        l[frame] += Float(sin(2 * .pi * freq * t) * exp(-t * 90) * 0.6)
                    }
                }
                i += 1
            }
            buf.floatChannelData![1].update(from: l, count: n)
            try file.write(from: buf)
            at += n
        }
    }
}

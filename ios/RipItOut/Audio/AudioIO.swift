import AVFoundation

/// Writing take audio the way stemtool/takes.py does: stereo 24-bit FLAC, and the take
/// moved onto the song timeline (same sample rate and length as the stems).
enum AudioIO {
    static let chunk: AVAudioFrameCount = 16384

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static func stereo(_ sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    /// Opens `<dir>/<name>.flac` for writing, or `<name>.wav` where this iOS can't
    /// encode FLAC. Returns the file and its name.
    static func openWriter(dir: URL, name: String, sampleRate: Double) throws -> (AVAudioFile, String) {
        let flac: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 24,
        ]
        let flacURL = dir.appendingPathComponent("\(name).flac")
        if let file = try? AVAudioFile(forWriting: flacURL, settings: flac, commonFormat: .pcmFormatFloat32, interleaved: false) {
            return (file, flacURL.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: flacURL)
        let wav: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let wavURL = dir.appendingPathComponent("\(name).wav")
        return (try AVAudioFile(forWriting: wavURL, settings: wav, commonFormat: .pcmFormatFloat32, interleaved: false),
                wavURL.lastPathComponent)
    }

    /// Copies `src` (any channel count) to stereo in `dst`, returning frames and peak.
    static func copyToStereo(_ src: AVAudioFile, _ dst: AVAudioFile) throws -> (frames: Int, peak: Float) {
        let inFormat = src.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: stereo(inFormat.sampleRate), frameCapacity: chunk) else {
            throw Failure.message("Out of memory")
        }
        var frames = 0
        var peak: Float = 0
        src.framePosition = 0
        while src.framePosition < src.length {
            try src.read(into: inBuf, frameCount: chunk)
            let n = Int(inBuf.frameLength)
            if n == 0 { break }
            let channels = Int(inFormat.channelCount)
            for ch in 0..<2 {
                let from = inBuf.floatChannelData![min(ch, channels - 1)]
                let to = outBuf.floatChannelData![ch]
                for i in 0..<n {
                    let v = from[i]
                    to[i] = v
                    peak = max(peak, abs(v))
                }
            }
            outBuf.frameLength = AVAudioFrameCount(n)
            try dst.write(from: outBuf)
            frames += n
        }
        return (frames, peak)
    }

    /// The take on the song timeline (stemtool/takes.py `_render_aligned`): `total`
    /// frames at `sampleRate`, the capture starting at song time `startS`, silence
    /// where nothing was captured. Returns the written file name.
    static func renderAligned(raw: URL, dir: URL, name: String, sampleRate: Double, total: Int, startS: Double) throws -> String {
        let src = try AVAudioFile(forReading: raw)
        let (out, filename) = try openWriter(dir: dir, name: name, sampleRate: sampleRate)
        let format = stereo(sampleRate)
        let startFrame = Int((startS * sampleRate).rounded())
        var written = 0

        func silence(_ frames: Int) throws {
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            for ch in 0..<2 { buf.floatChannelData![ch].update(repeating: 0, count: Int(chunk)) }
            var left = frames
            while left > 0 {
                let n = min(left, Int(chunk))
                buf.frameLength = AVAudioFrameCount(n)
                try out.write(from: buf)
                left -= n
            }
            written += frames
        }

        try silence(min(max(0, startFrame), total))
        var skip = max(0, -startFrame)  // capture frames (at the song rate) before song time 0

        try resampled(src, to: format) { buf in
            var from = 0
            let n = Int(buf.frameLength)
            if skip > 0 {
                from = min(skip, n)
                skip -= from
            }
            let take = min(n - from, total - written)
            guard take > 0 else { return written < total }
            if from == 0 && take == n {
                try out.write(from: buf)
            } else {
                let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(take))!
                for ch in 0..<2 {
                    part.floatChannelData![ch].update(from: buf.floatChannelData![ch] + from, count: take)
                }
                part.frameLength = AVAudioFrameCount(take)
                try out.write(from: part)
            }
            written += take
            return written < total
        }
        try silence(total - written)
        return filename
    }

    /// Streams `src` converted to `format` (stereo, another sample rate) in chunks.
    /// `body` returns false to stop early.
    static func resampled(_ src: AVAudioFile, to format: AVAudioFormat, _ body: (AVAudioPCMBuffer) throws -> Bool) throws {
        let inFormat = src.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { return }
        src.framePosition = 0

        if inFormat.sampleRate == format.sampleRate && inFormat.channelCount == 2 {
            while src.framePosition < src.length {
                try src.read(into: inBuf, frameCount: chunk)
                if inBuf.frameLength == 0 { return }
                let more = try body(inBuf)
                if !more { return }
            }
            return
        }

        guard let converter = AVAudioConverter(from: inFormat, to: format) else {
            throw Failure.message("Can't convert \(Int(inFormat.sampleRate)) Hz audio")
        }
        if inFormat.channelCount == 1 { converter.channelMap = [0, 0] }
        let ratio = format.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(chunk) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var finished = false
        var readError: Error?
        while true {
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                // AVAudioFile throws (without an error) when asked to read past the end
                if finished || src.framePosition >= src.length {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try src.read(into: inBuf, frameCount: chunk)
                } catch {
                    readError = error
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuf
            }
            if let readError { throw readError }
            if status == .error { throw convError ?? Failure.message("Conversion failed") }
            if outBuf.frameLength > 0 {
                let more = try body(outBuf)
                if !more { return }
            }
            if status == .endOfStream { return }
        }
    }

    /// Reads a whole (short) file as mono magnitude |L| + |R|, for calibration.
    static func magnitude(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        var out = [Float](repeating: 0, count: n)
        for ch in 0..<min(2, Int(format.channelCount)) {
            let data = buf.floatChannelData![ch]
            for i in 0..<n { out[i] += abs(data[i]) }
        }
        return (out, format.sampleRate)
    }
}

import Foundation

/// Beat grid helpers, the same rules as the desktop UI (stemtool/static/index.html):
/// bars and beats for the counter, and where a count-in starts.
struct Grid {
    let beats: [Double]
    let downbeats: [Double]
    let beatsPerBar: Int
    let bpm: Double?

    init(_ m: Manifest) {
        beats = m.beats
        downbeats = m.downbeats
        bpm = m.bpm
        beatsPerBar = m.beatsPerBar ?? Grid.estimateBeatsPerBar(beats: m.beats, downbeats: m.downbeats)
    }

    init(beats: [Double], downbeats: [Double], beatsPerBar: Int, bpm: Double? = nil) {
        self.beats = beats
        self.downbeats = downbeats
        self.beatsPerBar = beatsPerBar
        self.bpm = bpm
    }

    /// Index of the last element <= t, or -1.
    static func lastLE(_ a: [Double], _ t: Double) -> Int {
        var lo = 0, hi = a.count - 1, r = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if a[mid] <= t { r = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return r
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.sorted()[xs.count / 2]
    }

    static func estimateBeatsPerBar(beats: [Double], downbeats: [Double]) -> Int {
        guard downbeats.count >= 3, beats.count >= 4 else { return 4 }
        var freq: [Int: Int] = [:]
        for (d0, d1) in zip(downbeats, downbeats.dropFirst()) {
            let c = beats.filter { $0 >= d0 - 0.03 && $0 < d1 - 0.03 }.count
            if (2...12).contains(c) { freq[c, default: 0] += 1 }
        }
        return freq.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 4
    }

    /// Length of a beat around time t (median of the next beats).
    func beatInterval(at t: Double) -> Double {
        let i = max(0, Grid.lastLE(beats, t))
        let seg = Array(beats[min(i, beats.count)..<min(i + 9, beats.count)])
        let diffs = zip(seg, seg.dropFirst()).map { $1 - $0 }.filter { $0 > 0.15 && $0 < 2 }
        return Grid.median(diffs) ?? (bpm.map { 60 / $0 } ?? 0.5)
    }

    struct Position: Equatable {
        var bar: Int
        var beat: Int
        var down: Bool
    }

    func position(at t: Double) -> Position? {
        let di = Grid.lastLE(downbeats, t + 0.02)
        let bi = Grid.lastLE(beats, t + 0.02)
        guard di >= 0, bi >= 0 else { return nil }
        let beatTime = beats[bi]
        let n = beats.filter { $0 >= downbeats[di] - 0.03 && $0 <= beatTime + 0.001 }.count
        return Position(bar: di + 1, beat: min(n, 12), down: abs(beatTime - downbeats[di]) < 0.03)
    }

    /// Song time of the start of bar `bar` (1-based), for display.
    func barStart(_ bar: Int) -> Double? {
        bar >= 1 && bar <= downbeats.count ? downbeats[bar - 1] : nil
    }

    struct CountIn: Equatable {
        struct Click: Equatable {
            var s: Double   // song time of the click (before the start, can be negative)
            var down: Bool
        }
        var pos: Double     // where the song starts playing
        var clicks: [Click]
    }

    /// With a count-in, the start snaps back to the bar line and the clicks lead into
    /// the next downbeat.
    func planStart(from: Double, bars: Int) -> CountIn {
        guard bars > 0 else { return CountIn(pos: from, clicks: []) }
        var pos = from
        if from > 0.05 {
            let i = Grid.lastLE(downbeats, from + 0.05)
            if i >= 0 { pos = downbeats[i] }
        }
        let di = Grid.lastLE(downbeats, pos - 0.001) + 1
        var target = di < downbeats.count ? downbeats[di] : pos
        let interval = beatInterval(at: target)
        if target - pos > Double(beatsPerBar) * interval + 0.05 { target = pos } // long intro without beats
        let k = bars * beatsPerBar
        var clicks: [CountIn.Click] = []
        for j in stride(from: k, through: 1, by: -1) {
            var s = target - Double(j) * interval
            if s >= pos {
                let bi = Grid.lastLE(beats, s + interval / 3)
                if bi >= 0 && abs(beats[bi] - s) < interval / 3 { s = beats[bi] }
            }
            clicks.append(.init(s: s, down: (k - j) % beatsPerBar == 0))
        }
        return CountIn(pos: pos, clicks: clicks)
    }
}

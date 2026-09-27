import AVFoundation
import Observation

/// Plays a song's tracks (stems, click, and optionally a take) sample-accurately
/// together: every track has its own player node, and all of them start at the same
/// host time. Loops are scheduled as back-to-back segments on every player, so the
/// tracks wrap on the same sample. Recording and calibration share the engine, so the
/// input and the output run on one clock.
@MainActor
@Observable
final class PlayerEngine {
    struct Loop: Equatable {
        var a: Double
        var b: Double
    }

    private(set) var song: Song?
    private(set) var grid = Grid(beats: [], downbeats: [], beatsPerBar: 4)
    private(set) var trackKeys: [String] = []   // mixer order, "take" included when a take is loaded
    private(set) var take: Take?
    private(set) var isPlaying = false
    private(set) var loading = false
    private(set) var loop: Loop?
    private(set) var countInHosts: [Double] = []   // host seconds of the count-in clicks
    var countInBars: Int = UserDefaults.standard.object(forKey: "countInBars") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(countInBars, forKey: "countInBars") }
    }
    var error: String?
    var onEnded: (() -> Void)?
    /// Told when playback starts (host seconds at which `pos` plays) and stops (nil), so
    /// a take's video can follow.
    @ObservationIgnored var onTransport: ((_ host: Double?, _ pos: Double) -> Void)?

    private(set) var levels: [String: Float] = [:]

    @ObservationIgnored private(set) var engine = AVAudioEngine()
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    @ObservationIgnored private(set) var inputEnabled = false
    @ObservationIgnored private var settleUntil: Double = 0 // our own engine rebuild, not a device change
    @ObservationIgnored private var players: [String: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var files: [String: AVAudioFile] = [:]
    @ObservationIgnored private let countPlayer = AVAudioPlayerNode()
    @ObservationIgnored private var generation = 0
    private var offset: Double = 0   // observed: the playhead follows a jump while stopped
    @ObservationIgnored private var pos0: Double = 0
    @ObservationIgnored private(set) var startHost: Double = 0   // host seconds at which pos0 plays
    @ObservationIgnored private var activeLoop: Loop?
    @ObservationIgnored private var endTimer: Timer?

    var duration: Double { song?.manifest.durationS ?? 0 }
    var sampleRate: Double { Double(song?.manifest.sampleRate ?? 44100) }

    init() {
        configureSession()
        engine.attach(countPlayer)
        engine.connect(countPlayer, to: engine.mainMixerNode, format: AudioIO.stereo(44100))
        observe(engine)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    // MARK: - session and engine

    /// Playback only, until a Record page opens: then iOS doesn't count the microphone
    /// as in use (no orange dot) while you practise or listen back.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
    }

    func startEngine() {
        guard !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    /// Turns on the input (after the microphone permission was granted). An engine that
    /// already ran for playback alone often reports an input without channels, so the
    /// engine is built again with the input, and the tracks are attached to the new one.
    /// Returns what went wrong, or nil.
    func enableInput() -> String? {
        pause()
        let session = AVAudioSession.sharedInstance()
        do {
            // Only when it differs: every change makes iOS reconfigure the audio route.
            if session.category != .playAndRecord || !session.categoryOptions.contains(.defaultToSpeaker) {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try session.setActive(true)
        } catch {
            return "The audio session couldn't be set up for recording (\(error.localizedDescription))."
        }
        guard session.isInputAvailable else { return "iOS reports no audio input on this device right now." }
        if inputEnabled && engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 {
            startEngine()
            return nil
        }
        rebuildEngine()
        inputEnabled = true
        let format = engine.inputNode.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            let hw = engine.inputNode.inputFormat(forBus: 0)
            return "The input \(session.currentRoute.inputs.first?.portName ?? "?") reports \(Int(hw.sampleRate)) Hz with \(hw.channelCount) channels."
        }
        return nil
    }

    /// The session for recording (the Record page: inputs can be listed and chosen) or
    /// for playback only (everywhere else).
    func setRecordingSession(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        let isRecord = session.category == .playAndRecord
        guard on != isRecord else { return }
        do {
            if on {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
        startEngine()
    }

    /// Switches the microphone off again (leaving Record, the app going to the
    /// background): the engine is built again without the input, so iOS releases it.
    func disableInput() {
        guard inputEnabled else { return }
        let was = isPlaying
        pause()
        inputEnabled = false
        rebuildEngine(withInput: false)
        if was { play(countInBars: 0) }
    }

    /// In the background with nothing playing: let go of the audio session entirely.
    func suspend() {
        guard !isPlaying else { return }
        disableInput()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func rebuildEngine(withInput: Bool = true) {
        let old = engine
        old.stop()
        for p in players.values { old.detach(p) }
        old.detach(countPlayer)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }

        let fresh = AVAudioEngine()
        if withInput { _ = fresh.inputNode } // before anything runs, so the engine starts with the input
        fresh.attach(countPlayer)
        fresh.connect(countPlayer, to: fresh.mainMixerNode, format: AudioIO.stereo(44100))
        for (key, p) in players {
            guard let file = files[key] else { continue }
            fresh.attach(p)
            fresh.connect(p, to: fresh.mainMixerNode, format: file.processingFormat)
            p.volume = effectiveLevel(key)
        }
        engine = fresh
        settleUntil = Self.hostNow + 1
        observe(fresh)
        startEngine()
    }

    private func observe(_ engine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    @ObservationIgnored private var configPending = false

    /// A device came or went (headphones, an audio interface), or the input was switched
    /// on. iOS often sends several of these in a row, and restarting the engine can send
    /// another, so they are handled once, a moment later, and only if the engine really
    /// stopped.
    private func configurationChanged() {
        guard !configPending else { return }
        configPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        configPending = false
        if engine.isRunning { return }
        let was = isPlaying && Self.hostNow >= settleUntil
        if isPlaying { offset = position; stopAll() }
        startEngine()
        if was { onEnded?() } // a take being recorded is saved up to here
    }

    nonisolated static var hostNow: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    // MARK: - loading

    func load(_ song: Song) async {
        if self.song?.folder == song.folder && self.song?.manifest == song.manifest { return }
        pause()
        unloadTracks()
        self.song = song
        self.grid = Grid(song.manifest)
        self.take = nil
        self.loop = nil
        self.offset = 0
        self.zoom = 1
        loading = true
        defer { loading = false }

        var urls: [String: URL] = [:]
        for key in song.manifest.stemOrder { urls[key] = song.folder.appendingPathComponent(song.manifest.stems[key]!) }
        if let click = song.manifest.click?.audio { urls["click"] = song.folder.appendingPathComponent(click) }
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try Self.open(urls) }.value
            guard self.song?.folder == song.folder else { return }
            for key in song.manifest.stemOrder + ["click"] { if let f = opened[key] { add(key, f) } }
            trackKeys = song.manifest.stemOrder + (opened["click"] != nil ? ["click"] : [])
            startEngine()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Downloads (if needed) and opens the files. Blocks.
    nonisolated private static func open(_ urls: [String: URL]) throws -> [String: AVAudioFile] {
        var out: [String: AVAudioFile] = [:]
        for (key, url) in urls {
            try Files.download(url)
            out[key] = try AVAudioFile(forReading: url)
        }
        return out
    }

    private func add(_ key: String, _ file: AVAudioFile) {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        player.volume = effectiveLevel(key)
        players[key] = player
        files[key] = file
    }

    private func remove(_ key: String) {
        if let p = players.removeValue(forKey: key) {
            p.stop()
            engine.detach(p)
        }
        files[key] = nil
    }

    private func unloadTracks() {
        for key in Array(players.keys) { remove(key) }
        trackKeys = []
    }

    /// Plays a take along with the song ("My take" fader), or none.
    func loadTake(_ take: Take?) async {
        let was = isPlaying
        pause()
        remove("take")
        trackKeys.removeAll { $0 == "take" }
        soloed.remove("take")
        muted.remove("take")
        self.take = nil
        applyVolumes()
        guard let take else { return }
        do {
            let url = take.myTakeURL
            let file = try await Task.detached(priority: .userInitiated) { () throws -> AVAudioFile in
                try Files.download(url)
                return try AVAudioFile(forReading: url)
            }.value
            add("take", file)
            self.take = take
            trackKeys.append("take")
            startEngine()
            // Listening back starts where the take starts (at its bar), not where the
            // recording stopped, where the take is silent.
            if !was { offset = takeStart(take) }
            if was { play(countInBars: 0) }
        } catch {
            self.error = "Couldn't open the take: \(error.localizedDescription)"
        }
    }

    /// The bar line at or before the start of a take.
    func takeStart(_ take: Take) -> Double {
        let i = Grid.lastLE(grid.downbeats, take.startS + 0.05)
        return i >= 0 ? grid.downbeats[i] : max(0, take.startS)
    }

    /// Hear only the take (and the click, unless muted), or everything again.
    func setTakeOnly(_ on: Bool) {
        soloed = on ? ["take"] : []
        applyVolumes()
    }

    var takeOnly: Bool { soloed == ["take"] }

    // MARK: - levels

    func level(_ key: String) -> Float {
        if let v = levels[key] { return v }
        let stored = UserDefaults.standard.object(forKey: "level.\(key)") as? Float
        return stored ?? (key == "click" ? 0 : key == "count" ? 0.8 : 1)
    }

    func setLevel(_ key: String, _ value: Float) {
        levels[key] = value
        UserDefaults.standard.set(value, forKey: "level.\(key)")
        applyVolumes()
    }

    // MARK: - mute and solo (for this session only, like the desktop: a forgotten solo
    // would be confusing next time)

    private(set) var muted: Set<String> = []
    private(set) var soloed: Set<String> = []

    func toggleMute(_ key: String) {
        if muted.contains(key) { muted.remove(key) } else { muted.insert(key) }
        applyVolumes()
    }

    func toggleSolo(_ key: String) {
        if soloed.contains(key) { soloed.remove(key) } else { soloed.insert(key) }
        applyVolumes()
    }

    /// What a track plays at: its fader, unless muted, or unless another track is
    /// soloed. The click (and the count-in) is never silenced by another track's solo.
    func effectiveLevel(_ key: String) -> Float {
        if muted.contains(key) { return 0 }
        if !soloed.isEmpty && !soloed.contains(key) && key != "click" && key != "count" { return 0 }
        return level(key)
    }

    /// Every loaded track at the level you hear it (faders, mute, solo), for exporting.
    func mixSources() -> [TakeExport.Source] {
        trackKeys.compactMap { key in files[key].map { TakeExport.Source(url: $0.url, gain: effectiveLevel(key)) } }
    }

    func clearMutes() {
        muted = []
        applyVolumes()
    }

    private func applyVolumes() {
        for (key, p) in players { p.volume = effectiveLevel(key) }
        countPlayer.volume = effectiveLevel("count")
    }

    // MARK: - transport

    /// Song time now (what you hear, give or take the output latency).
    var position: Double {
        guard isPlaying else { return offset }
        var pos = pos0 + Self.hostNow - startHost
        if let L = activeLoop, pos >= L.b { pos = L.a + (pos - L.a).truncatingRemainder(dividingBy: L.b - L.a) }
        return min(max(0, pos), duration)
    }

    /// Seconds until the song starts (during a count-in), else 0.
    var countInRemaining: Double { isPlaying ? max(0, startHost - Self.hostNow) : 0 }

    @discardableResult
    func play(countInBars bars: Int? = nil) -> (host: Double, pos: Double)? {
        guard !isPlaying, song != nil, !players.isEmpty else { return nil }
        startEngine()
        guard engine.isRunning else { return nil }
        var from = offset >= duration - 0.05 ? 0 : offset
        if let L = loop, from < L.a || from >= L.b { from = L.a }
        var plan = grid.planStart(from: from, bars: bars ?? countInBars)
        if let L = loop, plan.pos < L.a { plan.pos = L.a } // the count-in may not snap out of the loop
        let lead = plan.clicks.first.map { max(0, plan.pos - $0.s) } ?? 0
        // With a count-in its clicks are the first sounds after silence: give the output a
        // moment (some USB interfaces swallow the first fraction of a second).
        let start = Self.hostNow + (plan.clicks.isEmpty ? 0.12 : 0.3) + lead

        generation += 1
        let gen = generation
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start))
        for (key, player) in players {
            guard let file = files[key] else { continue }
            schedule(player, file, from: plan.pos, loop: loop, gen: gen)
            player.play(at: when)
        }
        if !plan.clicks.isEmpty {
            let first = start + (plan.clicks[0].s - plan.pos)
            let buffer = Ticks.buffer(clicks: plan.clicks.map { ($0.s - plan.clicks[0].s, $0.down) })
            countPlayer.volume = effectiveLevel("count")
            countPlayer.scheduleBuffer(buffer, at: nil)
            countPlayer.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: first)))
        }
        countInHosts = plan.clicks.map { start + ($0.s - plan.pos) }
        activeLoop = loop
        pos0 = plan.pos
        startHost = start
        isPlaying = true
        onTransport?(start, plan.pos)
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEnd() }
        }
        return (start, plan.pos)
    }

    private func frames(_ file: AVAudioFile) -> AVAudioFramePosition {
        min(file.length, AVAudioFramePosition(song?.manifest.numSamples ?? Int(file.length)))
    }

    private func schedule(_ player: AVAudioPlayerNode, _ file: AVAudioFile, from pos: Double, loop: Loop?, gen: Int) {
        let sr = file.processingFormat.sampleRate
        let length = frames(file)
        let startFrame = min(length, AVAudioFramePosition((pos * sr).rounded()))
        guard let L = loop else {
            if length > startFrame {
                player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(length - startFrame), at: nil)
            }
            return
        }
        let a = min(length, AVAudioFramePosition((L.a * sr).rounded()))
        let b = min(length, AVAudioFramePosition((L.b * sr).rounded()))
        guard b > a else { return }
        if b > startFrame {
            player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(b - startFrame), at: nil)
        }
        // Two passes of the loop queued ahead; each finished pass queues the next.
        for _ in 0..<2 { queueLoop(player, file, a, b, gen) }
    }

    private func queueLoop(_ player: AVAudioPlayerNode, _ file: AVAudioFile, _ a: AVAudioFramePosition, _ b: AVAudioFramePosition, _ gen: Int) {
        player.scheduleSegment(file, startingFrame: a, frameCount: AVAudioFrameCount(b - a), at: nil,
                               completionCallbackType: .dataConsumed) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying, self.generation == gen else { return }
                    self.queueLoop(player, file, a, b, gen)
                }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        offset = position
        stopAll()
    }

    private func stopAll() {
        generation += 1
        if isPlaying { onTransport?(nil, position) }
        isPlaying = false
        countInHosts = []
        endTimer?.invalidate()
        endTimer = nil
        for p in players.values { p.stop() }
        countPlayer.stop()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(_ t: Double) {
        let was = isPlaying
        pause()
        offset = min(max(0, t), duration)
        if was { play(countInBars: 0) }
    }

    func setLoop(_ l: Loop?) {
        let was = isPlaying
        let pos = position
        pause()
        loop = l.flatMap { $0.b - $0.a > 0.2 ? $0 : nil }
        if let L = loop, pos < L.a || pos >= L.b { offset = L.a } else { offset = pos }
        if was { play(countInBars: 0) }
    }

    /// How far the tempo view is zoomed in (1 = the whole song).
    var zoom: Double = 1

    /// To the previous or next bar line (the previous one from just after a bar line).
    func stepBar(_ dir: Int) {
        let pos = position, db = grid.downbeats
        guard !db.isEmpty else { return }
        if dir < 0 {
            let i = Grid.lastLE(db, pos - 0.25)
            seek(i >= 0 ? db[i] : 0)
        } else if let next = db.first(where: { $0 > pos + 0.05 }) {
            seek(next)
        }
    }

    /// Moves the loop's start (or end) by `dir` bars, keeping at least one bar.
    func nudgeLoop(end: Bool, by dir: Int) {
        guard let L = loop else { return }
        let lines = Array(Set(([0] + grid.downbeats + [duration]).map { ($0 * 1000).rounded() / 1000 })).sorted()
        let edge = end ? L.b : L.a
        guard let i = lines.indices.min(by: { abs(lines[$0] - edge) < abs(lines[$1] - edge) }) else { return }
        let t = lines[max(0, min(lines.count - 1, i + dir))]
        let next = end ? Loop(a: L.a, b: t) : Loop(a: t, b: L.b)
        if next.b - next.a < 0.5 { return } // at least a bar
        setLoop(next)
    }

    /// Loops the section at the current position, or ends the loop.
    func toggleSectionLoop() {
        if loop != nil { setLoop(nil); return }
        guard let s = section(at: position) else { return }
        setLoop(Loop(a: s.start, b: s.end))
    }

    func section(at t: Double) -> Manifest.Section? {
        song?.manifest.sections?.last { $0.start <= t + 0.01 }
    }

    private func checkEnd() {
        guard isPlaying, activeLoop == nil, pos0 + Self.hostNow - startHost >= duration else { return }
        stopAll()
        offset = duration
        onEnded?()
    }

    // MARK: - clicks for calibration

    /// Plays clicks at host seconds `t0 + i * interval`, downbeat every `bpb`.
    func playClicks(t0: Double, count: Int, interval: Double, bpb: Int = 4) {
        let buffer = Ticks.buffer(clicks: (0..<count).map { (Double($0) * interval, $0 % bpb == 0) })
        countPlayer.volume = max(level("count"), 0.6)
        countPlayer.scheduleBuffer(buffer, at: nil)
        countPlayer.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: t0)))
    }

    func stopClicks() { countPlayer.stop() }
}

/// Click sounds, like the desktop's (stemtool/click.py): a short decaying sine, higher on the downbeat.
enum Ticks {
    static let sampleRate = 44100.0

    static func buffer(clicks: [(t: Double, down: Bool)]) -> AVAudioPCMBuffer {
        let tickLen = Int(0.035 * sampleRate)
        let total = Int(((clicks.map(\.t).max() ?? 0) * sampleRate).rounded()) + tickLen
        let buf = AVAudioPCMBuffer(pcmFormat: AudioIO.stereo(sampleRate), frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        l.update(repeating: 0, count: total)
        for c in clicks {
            let start = Int((c.t * sampleRate).rounded())
            let freq = c.down ? 1760.0 : 1100.0
            for i in 0..<tickLen where start + i < total {
                let t = Double(i) / sampleRate
                l[start + i] += Float(sin(2 * .pi * freq * t) * exp(-t * 90) * 0.6)
            }
        }
        r.update(from: l, count: total)
        return buf
    }
}

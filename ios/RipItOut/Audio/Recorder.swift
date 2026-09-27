import AVFoundation
import Observation

/// Captures the input into a local file from a tap on the engine's input node, and
/// remembers the host time of the first captured sample.
final class Capture: @unchecked Sendable {
    let url: URL
    private let file: AVAudioFile
    private let lock = NSLock()
    private var _firstHost: Double?
    private var _frames = 0
    private var _level: Float = 0
    private var failed: Error?

    init(format: AVAudioFormat) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString.prefix(8)).caf")
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        var peak: Float = 0
        let n = Int(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            let d = buffer.floatChannelData![ch]
            for i in 0..<n { peak = max(peak, abs(d[i])) }
        }
        lock.lock()
        defer { lock.unlock() }
        if _firstHost == nil {
            _firstHost = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : PlayerEngine.hostNow
        }
        do { try file.write(from: buffer) } catch { failed = error }
        _frames += n
        _level = max(peak, _level * 0.8)
    }

    var firstHost: Double? { lock.lock(); defer { lock.unlock() }; return _firstHost }
    var frames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
    var level: Float { lock.lock(); defer { lock.unlock() }; return _level }
    var sampleRate: Double { file.processingFormat.sampleRate }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failed }

    func discard() { try? FileManager.default.removeItem(at: url) }
}

/// Recording takes and measuring the latency. A take is saved in the same layout as the
/// desktop app's (stemtool/takes.py), so both apps list, play and export it.
@MainActor
@Observable
final class Recorder {
    enum State: Equatable { case idle, recording, saving, calibrating }

    private(set) var state: State = .idle
    private(set) var permission: Bool? = nil
    var note: String?
    /// The take just recorded, for "Take saved: Listen".
    private(set) var lastSaved: Take?
    var calibrationNote: String?

    @ObservationIgnored private let player: PlayerEngine
    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var started: (host: Double, pos: Double)?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored let camera = Camera()
    private(set) var cameraRunning = false
    private(set) var inputs: [AVAudioSessionPortDescription] = []

    /// Record video too (remembered). Front or back camera.
    var cameraOn: Bool = UserDefaults.standard.bool(forKey: "camera.on") {
        didSet { UserDefaults.standard.set(cameraOn, forKey: "camera.on") }
    }
    var frontCamera: Bool = UserDefaults.standard.object(forKey: "camera.front") as? Bool ?? true {
        didSet { UserDefaults.standard.set(frontCamera, forKey: "camera.front") }
    }

    init(player: PlayerEngine) {
        self.player = player
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = true
        case .denied: permission = false
        default: permission = nil
        }
        refreshInputs()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputs() }
        }
    }

    var level: Float { capture?.level ?? 0 }

    var inputName: String {
        _ = inputs // changes when the route changes, so views update
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Input"
    }

    // MARK: - choosing the input

    private static let inputKey = "input.preferred"

    /// The inputs iOS offers right now (iPhone microphone, headset, USB interface).
    func refreshInputs() {
        inputs = AVAudioSession.sharedInstance().availableInputs ?? []
    }

    var selectedInputUID: String? { AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid }

    func selectInput(_ uid: String) {
        guard let port = (AVAudioSession.sharedInstance().availableInputs ?? []).first(where: { $0.uid == uid }) else { return }
        UserDefaults.standard.set(uid, forKey: Self.inputKey)
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(port)
            calibrationNote = nil
        } catch {
            calibrationNote = "Couldn't switch to \(port.portName): \(error.localizedDescription)"
        }
        refreshInputs()
    }

    /// The input chosen earlier, when it's plugged in.
    private func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        guard let uid = UserDefaults.standard.string(forKey: Self.inputKey),
              session.currentRoute.inputs.first?.uid != uid,
              let port = (session.availableInputs ?? []).first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(port)
    }

    // MARK: - microphone on only while it's needed

    /// Set while a Record page is open; the microphone and the camera are switched off
    /// when it closes.
    var recordPageOpen = false {
        didSet {
            guard recordPageOpen != oldValue else { return }
            if recordPageOpen {
                player.setRecordingSession(true)
                refreshInputs()
            } else {
                releaseInput()
                Task { await updateCamera(active: false) }
            }
        }
    }

    /// Switches the microphone off unless something is being recorded or calibrated, and
    /// outside the Record page goes back to a playback-only session.
    func releaseInput() {
        guard state == .idle else { return }
        if tapInstalled { stopCapture() }
        player.disableInput()
        if !recordPageOpen { player.setRecordingSession(false) }
    }

    /// The app goes to the background: save a take being recorded, then let go of the
    /// microphone, the camera and the audio session.
    func appInBackground() async {
        if state == .recording { await stopRecording() }
        releaseInput()
        await updateCamera(active: false)
        player.suspend()
    }

    /// Back in the foreground: the camera again if a Record page is open (the microphone
    /// waits for Record or Calibrate).
    func appActive() async {
        player.startEngine()
        if recordPageOpen { await updateCamera(active: true) }
    }

    // MARK: - camera

    /// Starts or stops the camera preview to match the setting (while a song is open).
    func updateCamera(active: Bool) async {
        guard active, cameraOn, recordPageOpen else {
            if cameraRunning { let cam = camera; await Task.detached { cam.stop() }.value }
            cameraRunning = false
            return
        }
        guard await Camera.requestPermission() else {
            note = "Allow camera access in Settings > Privacy & Security > Camera to record video."
            cameraOn = false
            return
        }
        let cam = camera, front = frontCamera
        do {
            try await Task.detached { try cam.start(front: front) }.value
            cameraRunning = true
        } catch {
            note = error.localizedDescription
            cameraRunning = false
        }
    }

    // MARK: - latency

    private var latencyKey: String { "latency.\(inputName)" }

    /// The system's estimate: output + input latency and one buffer.
    var estimatedLatencyMs: Double {
        let s = AVAudioSession.sharedInstance()
        return ((s.outputLatency + s.inputLatency + s.ioBufferDuration) * 1000).rounded()
    }

    var latencyIsMeasured: Bool { UserDefaults.standard.object(forKey: latencyKey) != nil }

    var latencyMs: Double {
        get {
            _ = calibrationNote // changes whenever a new value is measured, so views update
            return UserDefaults.standard.object(forKey: latencyKey) as? Double ?? estimatedLatencyMs
        }
        set {
            UserDefaults.standard.set(newValue, forKey: latencyKey)
            calibrationNote = "Set by you"
        }
    }

    // MARK: - input

    func prepareInput() async -> Bool {
        if permission != true {
            permission = await AVAudioApplication.requestRecordPermission()
        }
        guard permission == true else {
            note = "Allow microphone access in Settings > Privacy & Security > Microphone to record."
            return false
        }
        applyPreferredInput()
        if let problem = player.enableInput() {
            note = problem
            calibrationNote = problem
            return false
        }
        return true
    }

    private func startCapture() throws -> Capture {
        let input = player.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioIO.Failure.message("No audio input: \(inputName) delivers \(Int(format.sampleRate)) Hz, \(format.channelCount) channels. Close other apps that use the microphone and try again.")
        }
        let cap = try Capture(format: format)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
            cap.append(buffer, when)
        }
        tapInstalled = true
        capture = cap
        return cap
    }

    private func stopCapture() {
        if tapInstalled {
            player.engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // MARK: - recording

    func toggleRecording() async {
        switch state {
        case .idle: await startRecording()
        case .recording: await stopRecording()
        default: break
        }
    }

    func startRecording() async {
        guard state == .idle, player.song != nil else { return }
        player.pause()
        guard await prepareInput() else { return }
        try? await Task.sleep(for: .milliseconds(400)) // let the engine settle with the input on
        player.setLoop(nil) // a take is one pass through the song
        note = nil
        lastSaved = nil
        do {
            _ = try startCapture()
        } catch {
            note = error.localizedDescription
            return
        }
        let withVideo = cameraOn && cameraRunning
        if withVideo { camera.startRecording() }
        guard let started = player.play() else {
            stopCapture()
            capture?.discard()
            capture = nil
            if withVideo { _ = await camera.stopRecording() }
            note = "Couldn't start playback."
            return
        }
        self.started = started
        state = .recording
        player.onEnded = { [weak self] in Task { await self?.stopRecording() } }
    }

    func stopRecording() async {
        guard state == .recording, let cap = capture, let started, let song = player.song else { return }
        player.onEnded = nil
        player.pause()
        stopCapture()
        capture = nil
        self.started = nil
        var video: (url: URL, firstHost: Double)?
        if cameraRunning { video = await camera.stopRecording() }
        guard let first = cap.firstHost else {
            cap.discard()
            state = .idle
            note = "Nothing was captured."
            return
        }
        let captureStartS = started.pos + (first - started.host)
        let captureEndS = captureStartS + Double(cap.frames) / cap.sampleRate
        if captureEndS <= started.pos + 0.5 {
            cap.discard()
            state = .idle
            note = "Stopped during the count-in, nothing saved."
            return
        }
        state = .saving
        note = "Saving take…"
        let latency = latencyMs, input = inputName
        let clip = video.map { (url: $0.url, startInCaptureS: $0.firstHost - first) }
        do {
            let take = try await Task.detached(priority: .userInitiated) {
                try TakeStore.save(song: song, capture: cap, captureStartS: captureStartS, latencyMs: latency, input: input, video: clip)
            }.value
            note = (take.peakDbfs ?? 0) < -45 ? "The take is almost silent. Check the input in Settings." : nil
            state = .idle
            lastSaved = take
            Uploads.shared.run()
        } catch {
            note = "Saving failed: \(error.localizedDescription)"
            state = .idle
        }
        cap.discard()
        if let video { try? FileManager.default.removeItem(at: video.url) }
    }

    // MARK: - calibration

    /// 20 clicks: listen to the first 4, then play a short note or hit with each of the
    /// others. The median distance from click to note is the round trip latency.
    func calibrate() async {
        guard state == .idle else { return }
        guard await prepareInput() else { return }
        try? await Task.sleep(for: .milliseconds(400)) // let the engine settle with the input on
        player.pause()
        state = .calibrating
        defer {
            state = .idle
            if !recordPageOpen { releaseInput() }
        }
        let interval = 0.5, count = 20, listen = 4
        let cap: Capture
        do { cap = try startCapture() } catch { calibrationNote = error.localizedDescription; return }
        defer { cap.discard(); capture = nil }
        let t0 = PlayerEngine.hostNow + 0.6
        player.playClicks(t0: t0, count: count, interval: interval)
        let end = t0 + Double(count) * interval + 0.5
        while PlayerEngine.hostNow < end {
            let k = Int(floor((PlayerEngine.hostNow - t0) / interval))
            calibrationNote = k < 0 ? "Get ready…" : k < listen ? "Listen… \(k + 1)"
                : "Play along with every click (\(min(count, k + 1) - listen) of \(count - listen))"
            try? await Task.sleep(for: .milliseconds(50))
        }
        stopCapture()
        player.stopClicks()
        guard let first = cap.firstHost, let got = try? AudioIO.magnitude(cap.url) else {
            calibrationNote = "Nothing was captured."
            return
        }
        let clicks = (0..<count).map { t0 + Double($0) * interval }
        switch Calibration.analyze(mono: got.samples, sampleRate: got.sampleRate, startTime: first, clicks: clicks, listen: listen) {
        case .success(let r):
            UserDefaults.standard.set(r.latencyMs, forKey: latencyKey)
            calibrationNote = "Measured \(Int(r.latencyMs)) ms from \(r.matched) notes (your timing varied by about ±\(Int(r.spreadMs)) ms)."
        case .failure(let e):
            calibrationNote = e.message
        }
    }
}

enum Calibration {
    struct Result { var latencyMs: Double; var matched: Int; var spreadMs: Double }
    struct Failure: Error { var message: String }

    /// Same analysis as the desktop: onsets above 30 % of the peak, each matched to the
    /// click it follows (between 80 ms early and 350 ms late).
    static func analyze(mono: [Float], sampleRate: Double, startTime: Double, clicks: [Double], listen: Int) -> Swift.Result<Result, Failure> {
        let peak = mono.max() ?? 0
        guard peak >= 0.02 else { return .failure(Failure(message: "No signal on this input. Check the input device.")) }
        let thr = peak * 0.3
        var onsets: [Double] = []
        var i = 0
        let hold = Int((0.15 * sampleRate).rounded())
        while i < mono.count {
            if mono[i] > thr {
                onsets.append(startTime + Double(i) / sampleRate)
                i += hold
            }
            i += 1
        }
        var deltas: [Double] = []
        for c in clicks.dropFirst(listen) {
            if let o = onsets.first(where: { $0 > c - 0.08 && $0 < c + 0.35 }) { deltas.append(o - c) }
        }
        guard deltas.count >= 8 else {
            return .failure(Failure(message: "Only \(deltas.count) notes matched the clicks. Try again: one short note or hit per click."))
        }
        let med = Grid.median(deltas)!
        let spread = Grid.median(deltas.map { abs($0 - med) })!
        return .success(Result(latencyMs: (med * 1000).rounded(), matched: deltas.count, spreadMs: (spread * 1000).rounded()))
    }
}

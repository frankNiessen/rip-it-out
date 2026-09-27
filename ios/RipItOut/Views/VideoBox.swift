import AVFoundation
import AVKit
import SwiftUI

/// Plays a take's video along with the song: started on the same host time as the
/// audio, and pulled back into place when it drifts or the loop wraps.
@MainActor
@Observable
final class TakeVideo {
    private(set) var player: AVPlayer?
    private(set) var takeID: String?
    private(set) var loading = false
    private(set) var problem: String?
    @ObservationIgnored private var startS: Double = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var engine: PlayerEngine?

    func show(_ take: Take?, engine: PlayerEngine) async {
        guard take?.id != takeID else { return }
        stop()
        player = nil
        problem = nil
        takeID = take?.id
        self.engine = engine
        guard let take, let url = take.videoURL, let start = take.videoStartS else { return }
        guard take.videoPlayable else {
            problem = "This take's video is a WebM file, which iOS can't play. Watch it in Rip It Out on your Mac."
            return
        }
        loading = true
        defer { loading = false }
        do {
            try await Background.run { try Files.download(url) }
        } catch {
            problem = "Couldn't load the video: \(error.localizedDescription)"
            return
        }
        guard takeID == take.id else { return }
        let p = AVPlayer(url: url)
        p.automaticallyWaitsToMinimizeStalling = false
        p.isMuted = true // the sound is the take on its own fader
        p.actionAtItemEnd = .pause
        startS = start
        player = p
        engine.onTransport = { [weak self] host, pos in self?.transport(host: host, pos: pos) }
        seek(engine.position)
    }

    private func transport(host: Double?, pos: Double) {
        guard let player else { return }
        guard let host else {
            player.pause()
            timer?.invalidate()
            seek(pos)
            return
        }
        let t = pos - startS
        let at = CMClockMakeHostTimeFromSystemUnits(AVAudioTime.hostTime(forSeconds: host + max(0, -t)))
        player.setRate(1, time: CMTime(seconds: max(0, t), preferredTimescale: 600), atHostTime: at)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepInPlace() }
        }
    }

    /// Loops and drift: when the picture is off by more than a quarter second, move it.
    private func keepInPlace() {
        guard let player, let engine, engine.isPlaying, engine.countInRemaining == 0 else { return }
        let want = engine.position - startS
        guard want >= 0 else { return }
        if abs(player.currentTime().seconds - want) > 0.25 {
            player.seek(to: CMTime(seconds: want + 0.05, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if player.rate == 0 { player.play() }
        }
    }

    private func seek(_ pos: Double) {
        player?.seek(to: CMTime(seconds: max(0, pos - startS), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        if engine?.onTransport != nil { engine?.onTransport = nil }
    }
}

/// The camera picture on the Record page, while Record video is on.
struct CameraBox: View {
    var height: CGFloat? = 240 // nil: as tall as there is room
    @Environment(Recorder.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        if recorder.cameraRunning {
            CameraPreview(session: recorder.camera.session, deviceID: recorder.cameraDeviceID)
                .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil)
                .frame(height: height)
                .background(Theme.hex(0x0b0c0d))
                .clipShape(.rect(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    // front or back camera, like the Camera app's switch
                    Button { recorder.frontCamera.toggle() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .disabled(recorder.state == .recording)
                    .accessibilityLabel(recorder.frontCamera ? "Switch to the back camera" : "Switch to the front camera")
                }
        }
    }
}

/// An AVPlayer without controls (the transport is the song's).
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

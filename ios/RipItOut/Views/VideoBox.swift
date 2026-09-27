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
    /// Width over height as it's shown (portrait or landscape), so the page fits the
    /// picture without bars around it.
    private(set) var aspect: CGFloat?
    @ObservationIgnored private var startS: Double = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var engine: PlayerEngine?

    func show(_ take: Take?, engine: PlayerEngine) async {
        guard take?.id != takeID else { return }
        stop()
        player = nil
        problem = nil
        aspect = nil
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
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(t)
            if r.height > 0 { aspect = abs(r.width / r.height) }
        }
        guard takeID == take.id else { return }
        let p = AVPlayer(url: url)
        p.automaticallyWaitsToMinimizeStalling = false
        p.isMuted = true // the sound is the take on its own fader
        p.actionAtItemEnd = .pause
        startS = start
        player = p
        Log.write("video of take \(take.id): starts at \(String(format: "%.3f", start)) s in the song")
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        @Bindable var recorder = recorder
        if recorder.cameraRunning {
            // the picture's own shape (720p, upright): no bars around it
            let aspect: CGFloat = verticalSizeClass == .compact ? 16 / 9 : 9 / 16
            CameraPreview(session: recorder.camera.session, deviceID: recorder.cameraDeviceID)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(height: height)
                .clipShape(.rect(cornerRadius: 3))
                .overlay(alignment: .topTrailing) {
                    // front or back camera, like the Camera app's switch
                    Button { recorder.frontCamera.toggle() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .disabled(recorder.state == .recording)
                    .accessibilityLabel(recorder.frontCamera ? "Switch to the back camera" : "Switch to the front camera")
                }
                .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil)
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
        v.playerLayer.videoGravity = .resizeAspectFill // the box has the video's shape
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

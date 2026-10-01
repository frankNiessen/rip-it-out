import AVFoundation
import SwiftUI

/// The camera for recording yourself on video, like the desktop's Record tab. It records
/// picture only (the sound is the take); the desktop adds the take's audio when it
/// exports a video. The first frame's time on the host clock places the video against
/// the capture, so no sound is needed to line it up (take.json video.sync = "clock").
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let output = AVCaptureVideoDataOutput()
    private var configuredPosition: AVCaptureDevice.Position?
    /// Knows which way up the phone is held, so a video recorded with the phone on its
    /// side is a landscape video.
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private(set) var device: AVCaptureDevice?

    // only touched on `queue`
    /// A video file ready to be written, made while the camera shows its picture: the
    /// first one set up the video encoder, which held everything up for two seconds
    /// (and the click and the recording with it) when it happened on pressing Record.
    private struct Prepared {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let url: URL
        let angle: CGFloat
    }
    private var prepared: Prepared?
    private var active: Prepared?  // the one being recorded
    private var wantAngle: CGFloat = 90
    private var recording = false
    private var firstHost: Double?

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestPermission() async -> Bool {
        if permission == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Starts the camera (preview) with the front or back camera. Blocks briefly.
    func start(front: Bool) throws {
        let position: AVCaptureDevice.Position = front ? .front : .back
        if configuredPosition != position {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                throw AudioIO.Failure.message("No camera on this side.")
            }
            let deviceInput = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.automaticallyConfiguresApplicationAudioSession = false // the audio engine owns the session
            for i in session.inputs { session.removeInput(i) }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            guard session.canAddInput(deviceInput) else {
                session.commitConfiguration()
                throw AudioIO.Failure.message("The camera can't be used right now.")
            }
            session.addInput(deviceInput)
            if !session.outputs.contains(output), session.canAddOutput(output) {
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(output)
            }
            if let c = output.connection(with: .video) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 } // portrait frames
                // The video is the right way round, also with the front camera: a
                // right-handed drummer stays right-handed (only the preview is a mirror,
                // like the Camera app's). Mirrored frames also turned the file's rotation
                // the wrong way, so landscape videos came out upside down.
                if c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = false
                }
            }
            session.commitConfiguration()
            configuredPosition = position
            queue.sync { discardPrepared() } // made for the other camera's frames
            self.device = device
            rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
        if !session.isRunning {
            session.startRunning()
            Log.write("camera on (\(front ? "front" : "back"))")
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        queue.sync { discardPrepared() }
    }

    var isRunning: Bool { session.isRunning }

    func startRecording() {
        // Which way up, fixed for the whole video: stored as the file's rotation, not by
        // turning the camera's output while recording starts.
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        queue.sync {
            wantAngle = angle
            if prepared?.angle != angle { discardPrepared() } // held another way: made at the first frame
            active = prepared
            prepared = nil
            firstHost = nil
            recording = true
        }
    }

    /// Finishes the file. Returns it and the host time of its first frame, or nil if
    /// no frame was recorded.
    func stopRecording() async -> (url: URL, firstHost: Double)? {
        let state: (Prepared?, Double?) = queue.sync {
            recording = false
            defer { active = nil }
            return (active, firstHost)
        }
        guard let p = state.0 else { return nil }
        guard let first = state.1, p.writer.status == .writing else {
            p.writer.cancelWriting()
            try? FileManager.default.removeItem(at: p.url)
            return nil
        }
        p.input.markAsFinished()
        await p.writer.finishWriting()
        return p.writer.status == .completed ? (p.url, first) : nil
    }

    private func discardPrepared() {
        guard let p = prepared else { return }
        p.writer.cancelWriting()
        try? FileManager.default.removeItem(at: p.url)
        prepared = nil
    }

    /// A writer for frames like this one, already writing (the encoder set up).
    private func makeWriter(like sample: CMSampleBuffer, angle: CGFloat) -> Prepared? {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString.prefix(8)).mp4")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidth(image),
            AVVideoHeightKey: CVPixelBufferGetHeight(image),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        i.transform = CGAffineTransform(rotationAngle: (angle - 90) * .pi / 180)
        guard w.canAdd(i) else { return nil }
        w.add(i)
        w.shouldOptimizeForNetworkUse = true
        let t = PlayerEngine.hostNow
        guard w.startWriting() else { return nil }
        Log.write("video writer ready (took \(Log.ms(PlayerEngine.hostNow - t)))")
        return Prepared(writer: w, input: i, url: url, angle: angle)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording else {
            // Showing the picture: have the next video file ready.
            if prepared == nil {
                let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
                prepared = makeWriter(like: sampleBuffer, angle: angle)
            }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if active == nil { active = makeWriter(like: sampleBuffer, angle: wantAngle) }
        guard let p = active, p.writer.status == .writing else { return }
        if firstHost == nil {
            p.writer.startSession(atSourceTime: pts)
            // The capture clock to the host clock, which the audio engine uses too.
            let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
            firstHost = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            if let firstHost { Log.write("video first frame: \(Log.ms(firstHost - PlayerEngine.hostNow)) from now") }
        }
        if p.input.isReadyForMoreMediaData {
            p.input.append(sampleBuffer)
        }
    }
}

/// The live camera picture, upright however the phone is held.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var deviceID: String?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?
        private var deviceID: String?

        /// Follows the camera in use (it changes when you flip it).
        func follow(_ id: String?, force: Bool = false) {
            guard force || id != deviceID || rotation == nil else { return }
            deviceID = id
            observation = nil
            rotation = nil
            guard let id, let device = AVCaptureDevice(uniqueID: id) else { return }
            let r = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotation = r
            apply(r.videoRotationAngleForHorizonLevelPreview)
            observation = r.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] r, _ in
                let angle = r.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.apply(angle) }
            }
        }

        // Turning the phone lays the view out again: take the new angle right then
        // (waiting for the coordinator's change notice took seconds).
        override func layoutSubviews() {
            super.layoutSubviews()
            if rotation == nil || previewLayer.connection == nil { follow(deviceID, force: true) }
            if let r = rotation { apply(r.videoRotationAngleForHorizonLevelPreview) }
        }

        private func apply(_ angle: CGFloat) {
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill // the box has the picture's shape
        v.follow(deviceID)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.follow(deviceID)
    }
}

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
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var recording = false
    private var firstHost: Double?
    private var url: URL?
    private var transform = CGAffineTransform.identity

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
                if c.isVideoMirroringSupported { c.isVideoMirrored = front }
            }
            session.commitConfiguration()
            configuredPosition = position
            self.device = device
            rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    var isRunning: Bool { session.isRunning }

    func startRecording() {
        // Which way up, fixed for the whole video: stored as the file's rotation, not by
        // turning the camera's output while recording starts (that reconfigured the
        // capture, and the audio with it: the click died).
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let turn = CGAffineTransform(rotationAngle: (angle - 90) * .pi / 180)
        queue.sync {
            transform = turn
            url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString.prefix(8)).mp4")
            writer = nil
            input = nil
            firstHost = nil
            recording = true
        }
    }

    /// Finishes the file. Returns it and the host time of its first frame, or nil if
    /// no frame was recorded.
    func stopRecording() async -> (url: URL, firstHost: Double)? {
        let state: (AVAssetWriter?, AVAssetWriterInput?, Double?, URL?) = queue.sync {
            recording = false
            return (writer, input, firstHost, url)
        }
        guard let writer = state.0, let first = state.2, let url = state.3, writer.status == .writing else { return nil }
        state.1?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? (url, first) : nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, let url else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: CVPixelBufferGetWidth(image),
                AVVideoHeightKey: CVPixelBufferGetHeight(image),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
            ]
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            i.transform = transform
            guard w.canAdd(i) else { return }
            w.add(i)
            w.shouldOptimizeForNetworkUse = true
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts)
            writer = w
            input = i
            // The capture clock to the host clock, which the audio engine uses too.
            let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
            firstHost = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            if let firstHost { Log.write("video first frame: \(Log.ms(firstHost - PlayerEngine.hostNow)) from now (capture clock \(clock === CMClockGetHostTimeClock() ? "is" : "isn't") the host clock)") }
        }
        if let input, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
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

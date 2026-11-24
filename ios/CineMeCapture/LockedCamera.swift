import AVFoundation
import UIKit

/// The lock screen camera's camera: one lens, the app's format (or 4K30 SDR HEVC if that can't be
/// done), automatic exposure, focus and white balance, video with sound. Clips go to [folder] (the
/// session folder). The session runs on [queue]; what the screen shows is published on the main thread.
final class LockedCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cineme.locked")
    private let movie = AVCaptureMovieFileOutput()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var previewAngle: NSKeyValueObservation?
    private var isRAW = false
    private var starting = false
    let folder: URL
    /// Set by the preview before the camera starts (main thread).
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    @Published var formatText = ""
    @Published var problem: String? = nil
    @Published var recording = false
    @Published var recordStart = Date()
    @Published var saved = 0
    /// No camera permission: only the app can ask for it.
    @Published var denied = false

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    func publish(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    // MARK: - start / stop

    func start(_ ctx: CaptureContext?) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: open(ctx)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.open(ctx) } else { self.publish { self.denied = true } }
            }
        default: denied = true
        }
    }

    private func open(_ ctx: CaptureContext?) {
        queue.async {
            if !self.session.inputs.isEmpty {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            self.session.beginConfiguration()
            self.build(ctx)
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    /// Ends a take (the clip is kept) and closes the camera.
    func stop() {
        queue.async {
            if self.movie.isRecording { self.movie.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// The session for the app's choices. On [queue], inside a configuration.
    private func build(_ ctx: CaptureContext?) {
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        let lens = Lens(rawValue: ctx?.lens ?? "") ?? .main
        guard let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            publish { self.problem = "Couldn't open the camera" }
            return
        }
        session.addInput(input)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio), let a = try? AVCaptureDeviceInput(device: mic), session.canAddInput(a) {
            session.addInput(a)
        }
        guard session.canAddOutput(movie) else {
            publish { self.problem = "Couldn't record with this camera" }
            return
        }
        session.addOutput(movie)

        // The app's format, else 4K30 SDR HEVC, else what the camera has.
        var res = Resolution(rawValue: ctx?.resolution ?? "") ?? .uhd
        var fps = ctx?.fps ?? 30
        var look = Look(rawValue: ctx?.look ?? "") ?? .sdr
        var codec = Codec(rawValue: ctx?.codec ?? "") ?? .hevc
        if !codec.allows(look) { look = .sdr }
        var fmt = pickFormat(dev, res: res, fps: fps, look: look, codec: codec)
        if fmt == nil {
            res = .uhd; fps = 30; look = .sdr; codec = .hevc
            fmt = pickFormat(dev, res: res, fps: fps, look: look, codec: codec)
        }
        isRAW = codec.isRAW
        if let fmt = fmt, (try? dev.lockForConfiguration()) != nil {
            dev.activeFormat = fmt
            if !codec.isRAW, let cs = AVCaptureColorSpace(rawValue: look.colorSpaceRaw), fmt.supportedColorSpaces.contains(cs) {
                dev.activeColorSpace = cs
            }
            let d = CMTime(value: 1, timescale: CMTimeScale(fps))
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
            dev.videoZoomFactor = min(lens.crop, fmt.videoMaxZoomFactor)
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            dev.unlockForConfiguration()
        }
        if let c = movie.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = (ctx?.stabilization ?? false) ? .cinematic : .off }
            if movie.availableVideoCodecTypes.contains(codec.type) { movie.setOutputSettings([AVVideoCodecKey: codec.type], for: c) }
        }
        let text = fmt == nil ? "Video" : "\(res.rawValue)\(fps) \(codec.isRAW ? "" : look.rawValue.replacingOccurrences(of: " (Dolby Vision)", with: "") + " · ")\(codec.rawValue)"
        let layer = previewLayer
        publish {
            self.formatText = text
            if let layer = layer { self.watchPreview(dev, layer) }
        }
    }

    /// Keeps the preview level as the phone turns, and gives the angle for the clip. Main thread.
    private func watchPreview(_ dev: AVCaptureDevice, _ layer: AVCaptureVideoPreviewLayer) {
        let r = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: layer)
        queue.async { self.rotation = r }
        previewAngle = r.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { r, _ in
            let a = r.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                if let c = layer.connection, c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
            }
        }
    }

    // MARK: - recording

    /// The record key, the Camera Control and the volume keys.
    func toggleRecord() {
        queue.async {
            if self.movie.isRecording { self.movie.stopRecording(); return }
            guard !self.starting, self.session.isRunning, self.session.outputs.contains(self.movie) else { return }
            self.starting = true
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            let url = self.folder.appendingPathComponent("CineMe_" + Self.stamp.string(from: Date()) + ".mov")
            if let c = self.movie.connection(with: .video), let r = self.rotation, !self.isRAW {
                let a = r.videoRotationAngleForHorizonLevelCapture
                if c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
            }
            self.movie.startRecording(to: url, recordingDelegate: self)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { self.starting = false }
        publish { self.recording = true; self.recordStart = Date(); self.problem = nil }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async { self.starting = false }
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let there = FileManager.default.fileExists(atPath: url.path)
        publish {
            self.recording = false
            if ok && there { self.saved += 1 } else { self.problem = "Video not recorded: \(error?.localizedDescription ?? "no file")" }
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

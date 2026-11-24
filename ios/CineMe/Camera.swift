import AVFoundation
import Photos
import UIKit

/// The camera: one lens at a time, manual exposure, white balance, focus and aperture, and recording
/// with AVCaptureMovieFileOutput (the only output that records ProRes RAW). The session runs on
/// [queue]; what the screen shows is published on the main thread.
final class Camera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cineme.camera")
    private let movie = AVCaptureMovieFileOutput()
    /// Frames for tracking and time-lapse (Timelapse.swift, Tracking.swift). Only in the session while
    /// one of them needs it: since iOS 16 it may run next to the movie output, but not with ProRes.
    let frames = AVCaptureVideoDataOutput()
    let framesQueue = DispatchQueue(label: "cineme.frames")
    /// Photo mode: the photo output and the photo being taken (Photo.swift).
    let photo = PhotoTaker()
    /// Who wants frames. On [queue].
    private var framesFor: Set<FrameUse> = []
    /// Every frame while tracking (or the arms trigger) is on: pixel buffer upright as on screen. On [framesQueue].
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Every frame while a picture aid is on (histogram, peaking, sharp areas: Aids.swift). On [framesQueue].
    var onAidFrame: ((CVPixelBuffer) -> Void)?
    /// The frames had to stop (a ProRes codec was chosen): tracking turns off. Main thread.
    var onFramesDropped: (() -> Void)?
    /// The frames had to stop for the picture aids (why). Main thread.
    var onAidsDropped: ((String) -> Void)?
    /// The running time-lapse, on [framesQueue] (Timelapse.swift).
    var tlRun: TimelapseRun?
    /// After each time-lapse photo (shots so far, all) and at the end. Main thread.
    var onTimelapseShot: ((Int, Int) -> Void)?
    var onTimelapseEnd: (() -> Void)?
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private(set) var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    // What the user chose (kept between launches).
    @Published var lens: Lens = Lens(rawValue: UserDefaults.standard.string(forKey: "lens") ?? "") ?? .main
    @Published var resolution: Resolution = Resolution(rawValue: UserDefaults.standard.string(forKey: "res") ?? "") ?? .uhd
    @Published var fps: Int = UserDefaults.standard.object(forKey: "fps") as? Int ?? 30
    @Published var look: Look = Look(rawValue: UserDefaults.standard.string(forKey: "look") ?? "") ?? .sdr
    @Published var codec: Codec = Codec(rawValue: UserDefaults.standard.string(forKey: "codec") ?? "") ?? .hevc
    @Published var stabilization: Bool = UserDefaults.standard.object(forKey: "stab") as? Bool ?? false

    // Manual controls.
    @Published var autoExposure = true
    @Published var iso: Float = 100
    @Published var shutter: Int32 = 50          // 1/50 s
    @Published var autoWB = true
    @Published var kelvin: Float = 5600
    @Published var autoFocus = true
    @Published var focus: Float = 0.5           // lens position 0 (near) .. 1 (far)
    /// Aperture (iPhone 18 Pro, iOS 27): nil = the camera chooses.
    @Published var aperture: Float? = nil
    @Published var apertureStops: [Float] = []
    /// Where Auto aims: -10 (darker) .. +10 (brighter), each step 0.2 stop (Android: Settings > Auto).
    @Published var autoBias: Int = UserDefaults.standard.integer(forKey: "autoBias") {
        didSet { UserDefaults.standard.set(autoBias, forKey: "autoBias"); setExposure() }
    }

    // What the camera reports back.
    @Published var formatText = ""
    @Published var problem: String? = nil
    @Published var recording = false
    @Published var recordStart = Date()
    @Published var message: String? = nil
    @Published var notRecorded: String? = nil
    @Published var isoRange: ClosedRange<Float> = 25...12800
    @Published var formatsList: [String] = []
    @Published var lenses: [Lens] = []
    /// A time-lapse running (Timelapse.swift); [recording] is true with it.
    @Published var timelapse: TimelapseState? = nil

    /// External drive folder (USB-C), for ProRes 4K at 120 fps; nil = the phone.
    @Published var externalName: String? = UserDefaults.standard.string(forKey: "extName")
    private var externalURL: URL?

    // MARK: - start

    func start() {
        photo.camera = self
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { self.publish { self.problem = "Allow the camera in Settings > CineMe" }; return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.queue.async {
                    self.findLenses()
                    self.configure()
                    self.session.startRunning()
                }
            }
        }
    }

    /// Screenshot runs on the simulator (no camera): what an iPhone 18 Pro would show, so the screens look real.
    func fakeForShots() {
        lenses = Lens.allCases
        look = .hdr
        formatText = "4K30 HDR (Dolby Vision) · HEVC"
        apertureStops = [1.48, 1.8, 2.8, 4.0]
        isoRange = 25...6400
        formatsList = ["3840x2160 · 10-bit · 1-120 fps · sRGB, HLG, Log 2", "3840x2160 · RAW bgg4 · 1-60 fps · ", "1920x1080 · 8-bit · 1-240 fps · sRGB, P3"]
    }

    func stop() {
        // A time-lapse ends with the session (the clip so far is kept).
        framesQueue.async { if self.tlRun != nil { self.finishTimelapse() } }
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func publish(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    private func findLenses() {
        let found = Lens.allCases.filter { AVCaptureDevice.default($0.deviceType, for: .video, position: .back) != nil }
        publish { self.lenses = found }
    }

    /// Builds the session for the current choices. On [queue].
    private func configure() {
        session.beginConfiguration()
        build()
        session.commitConfiguration()
        // The frames output beside the movie output can be more than the camera can do at a big size
        // and frame rate (then the session wouldn't run): the frames go, the movie stays.
        if session.outputs.contains(frames), !framesFor.contains(.timelapse), session.hardwareCost > 1 {
            dropFrames("too much for the camera at this size and frame rate")
        }
    }

    /// The inside of [configure], in one session configuration. On [queue].
    private func build() {
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        guard let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            publish { self.problem = "This lens isn't on this phone" }
            return
        }
        if input?.device != dev {
            if let i = input { session.removeInput(i) }
            guard let i = try? AVCaptureDeviceInput(device: dev), session.canAddInput(i) else {
                publish { self.problem = "Couldn't open the camera" }
                return
            }
            session.addInput(i)
            input = i
            device = dev
            if let layer = previewLayer {
                rotation = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: layer)
            }
        }
        if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio), let a = try? AVCaptureDeviceInput(device: mic), session.canAddInput(a) {
            session.addInput(a)
            audioInput = a
        }
        // Sound: mono / stereo / spatial, wind, AirPods (ProAV.swift).
        if let a = audioInput { ProAV.apply(to: a, session: session) }
        // Photo mode: preset .photo and the photo output, no movie output (Photo.swift). Its sizes,
        // ProRAW and the lens crop are set after this configuration is committed.
        if photo.queueOn {
            guard photo.configure(session: session, movie: movie) else {
                publish { self.problem = "Photo mode isn't possible with this camera" }
                return
            }
            SoundMeter.shared.remove(from: session)
            if !framesFor.isEmpty, !session.outputs.contains(frames), !attachFrames() {
                dropFrames("the camera can't send frames in photo mode")
            }
            if session.outputs.contains(frames) { rotateFrames() }
            let list = dev.formats.map { $0.summary }
            let crop = lens.crop
            publish { self.formatsList = list }
            queue.async {
                let text = self.photo.finish(session: self.session, device: dev, crop: crop)
                self.publish { self.formatText = text; self.problem = nil }
                self.applyAll()
            }
            return
        }
        photo.remove(from: session)
        // (A time-lapse takes the movie output out while it runs: it writes its own file.)
        if !framesFor.contains(.timelapse), !session.outputs.contains(movie), session.canAddOutput(movie) { session.addOutput(movie) }
        // The sound meters' own audio output, beside the movie output (SoundMeter.swift).
        SoundMeter.shared.install(in: session, movie: movie)
        // ProRes can't share the camera with the frames output (seen failing on iOS 26): tracking and
        // the picture aids stop. (A time-lapse takes the movie output out, so its frames are safe.)
        if codec.isProRes, !framesFor.contains(.timelapse), !framesFor.isDisjoint(with: [.tracking, .aids]) {
            dropFrames("it doesn't work with ProRes")
        } else if !framesFor.isEmpty, !session.outputs.contains(frames) {
            // Asked for before the camera was open (the picture aids at launch).
            if !attachFrames() { dropFrames("the camera can't send frames with this format") }
        }
        // A new lens makes new connections: the frames upright again.
        if session.outputs.contains(frames) { rotateFrames() }

        let list = dev.formats.map { $0.summary }
        publish { self.formatsList = list }

        guard let fmt = pickFormat(dev, res: resolution, fps: fps, look: look, codec: codec) else {
            let what = "\(resolution.rawValue) \(fps) fps \(codec.isRAW ? "" : look.rawValue + " ")\(codec.rawValue)"
            publish { self.problem = "\(self.lens.label) can't record \(what)"; self.formatText = what }
            return
        }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = fmt
            if !codec.isRAW, let cs = AVCaptureColorSpace(rawValue: look.colorSpaceRaw), fmt.supportedColorSpaces.contains(cs) {
                dev.activeColorSpace = cs
            }
            let d = CMTime(value: 1, timescale: CMTimeScale(fps))
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
            dev.videoZoomFactor = min(lens.crop, dev.activeFormat.videoMaxZoomFactor)
            dev.unlockForConfiguration()
        } catch {
            publish { self.problem = "Camera busy: \(error.localizedDescription)" }
            return
        }
        if let c = movie.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = stabilization ? .cinematic : .off }
            if movie.availableVideoCodecTypes.contains(codec.type) {
                movie.setOutputSettings([AVVideoCodecKey: codec.type], for: c)
            }
        }
        let codecOK = movie.availableVideoCodecTypes.contains(codec.type)
        let range = fmt.minISO...fmt.maxISO
        let stops = apertureStopsOf(fmt)
        let text = "\(resolution.rawValue)\(fps) \(codec.isRAW ? "" : look.rawValue + " · ")\(codec.rawValue)"
        publish {
            self.isoRange = range
            self.apertureStops = stops
            if let a = self.aperture, !stops.contains(a) { self.aperture = nil }
            self.formatText = text
            self.problem = codecOK ? nil : "\(self.codec.rawValue) isn't offered for this format"
        }
        applyAll()
    }

    /// Settings > Sound changed: only the mic input changes (ProAV.swift).
    func applySound() {
        queue.async {
            guard let a = self.audioInput else { return }
            self.session.beginConfiguration()
            ProAV.apply(to: a, session: self.session)
            self.session.commitConfiguration()
        }
    }

    /// Changes that need a new format (lens, size, fps, look, codec).
    func reconfigure() {
        let d = UserDefaults.standard
        d.set(lens.rawValue, forKey: "lens"); d.set(resolution.rawValue, forKey: "res"); d.set(fps, forKey: "fps")
        d.set(look.rawValue, forKey: "look"); d.set(codec.rawValue, forKey: "codec"); d.set(stabilization, forKey: "stab")
        queue.async { self.configure() }
    }

    /// Sound meters on or off in Settings (SoundMeter.swift): their output in or out. Video mode only.
    func refreshSoundMeter() {
        queue.async {
            guard self.device != nil, !self.photo.queueOn, !self.movie.isRecording else { return }
            self.session.beginConfiguration()
            SoundMeter.shared.install(in: self.session, movie: self.movie)
            self.session.commitConfiguration()
        }
    }

    // MARK: - exposure, white balance, focus, aperture

    func applyAll() { queue.async { self.applyExposure(); self.applyWB(); self.applyFocus() } }
    func setExposure() { queue.async { self.applyExposure() } }
    func setWB() { queue.async { self.applyWB() } }
    func setFocus() { queue.async { self.applyFocus() } }

    private func applyExposure() {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        let fmt = dev.activeFormat
        let maxDur = CMTime(value: 1, timescale: CMTimeScale(fps))
        var dur = CMTime(value: 1, timescale: shutter)
        if CMTimeCompare(dur, maxDur) > 0 { dur = maxDur }
        if CMTimeCompare(dur, fmt.minExposureDuration) < 0 { dur = fmt.minExposureDuration }
        let isoNow = min(max(iso, fmt.minISO), fmt.maxISO)
        if autoExposure {
            let bias = min(max(Float(autoBias) * 0.2, dev.minExposureTargetBias), dev.maxExposureTargetBias)
            if dev.exposureTargetBias != bias { dev.setExposureTargetBias(bias, completionHandler: nil) }
        }
        if setAperture(dev, duration: autoExposure ? nil : dur, iso: autoExposure ? nil : isoNow) { return }
        if autoExposure {
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        } else if dev.isExposureModeSupported(.custom) {
            dev.setExposureModeCustom(duration: dur, iso: isoNow, completionHandler: nil)
        }
    }

    private func applyWB() {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        if autoWB {
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            return
        }
        guard dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
        var g = dev.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0))
        let top = dev.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), top)
        g.greenGain = min(max(g.greenGain, 1), top)
        g.blueGain = min(max(g.blueGain, 1), top)
        dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
    }

    private func applyFocus() {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        if autoFocus {
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        } else if dev.isLockingFocusWithCustomLensPositionSupported {
            dev.setFocusModeLocked(lensPosition: min(max(focus, 0), 1), completionHandler: nil)
        }
    }

    /// Manual focus from where the autofocus is now, so the focus ring starts there (no jump).
    func manualFocusHere() {
        if autoFocus, let d = device { focus = d.lensPosition }
        autoFocus = false
        setFocus()
    }

    /// The white balance the camera measures now, in Kelvin (the WB dial shows it in Auto).
    func measuredKelvin() -> Float? {
        guard let d = device, d.maxWhiteBalanceGain >= 1 else { return nil }
        var g = d.deviceWhiteBalanceGains
        let top = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), top)
        g.greenGain = min(max(g.greenGain, 1), top)
        g.blueGain = min(max(g.blueGain, 1), top)
        let k = d.temperatureAndTintValues(for: g).temperature
        return k.isFinite && k > 0 ? k : nil
    }

    /// Tap to focus (and expose, in auto) on a point of the preview, 0..1 in the camera's frame.
    func focus(at p: CGPoint) {
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = p }
            if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = self.autoFocus ? .continuousAutoFocus : .autoFocus }
            if self.autoExposure, dev.isExposurePointOfInterestSupported {
                dev.exposurePointOfInterest = p
                dev.exposureMode = .continuousAutoExposure
            }
        }
    }

    /// The aperture stops the active format offers (iPhone 18 Pro Fusion Main: f/1.48, 1.8, 2.8, 4.0). Empty = fixed.
    private func apertureStopsOf(_ fmt: AVCaptureDevice.Format) -> [Float] {
        #if HAS_IOS27_SDK
        if #available(iOS 27.0, *) {
            guard fmt.minLensAperture < fmt.maxLensAperture else { return [] }
            return fmt.recommendedLensApertureStops.filter {
                fmt.supportsExposureModeCustom(lensAperture: $0, duration: AVCaptureDevice.autoExposureDuration, iso: AVCaptureDevice.autoISO)
            }
        }
        #endif
        return []
    }

    /// Sets exposure with the chosen aperture (duration / iso nil = the camera chooses that one).
    /// False if there's no aperture to set, so the normal exposure path runs.
    private func setAperture(_ dev: AVCaptureDevice, duration: CMTime?, iso: Float?) -> Bool {
        #if HAS_IOS27_SDK
        if #available(iOS 27.0, *), let a = aperture {
            let d = duration ?? AVCaptureDevice.autoExposureDuration
            let i = iso ?? AVCaptureDevice.autoISO
            guard dev.activeFormat.supportsExposureModeCustom(lensAperture: a, duration: d, iso: i) else { return false }
            dev.setExposureModeCustom(lensAperture: a, duration: d, iso: i, completionHandler: nil)
            return true
        }
        #endif
        return false
    }

    // MARK: - steps (gimbal slider, remote)

    /// One third of a stop brighter (+1) or darker (-1): shutter first (down to 1/fps), then ISO. Like Android.
    func exposureStep(_ dir: Int) {
        let shutters = shutterDenominators.filter { $0 >= Int32(fps) }
        let isos = isoSteps.filter { isoRange.contains($0) }
        guard !shutters.isEmpty, !isos.isEmpty else { return }
        if autoExposure { autoExposure = false; captureAutoValues() }
        var s = shutters.firstIndex { $0 >= shutter } ?? 0
        var i = isos.firstIndex { $0 >= iso } ?? 0
        if dir > 0 {
            if s > 0 { s -= 1 } else if i < isos.count - 1 { i += 1 }
        } else {
            if i > 0 { i -= 1 } else if s < shutters.count - 1 { s += 1 }
        }
        shutter = shutters[s]; iso = isos[i]
        publishMessage("ISO \(Int(iso)), 1/\(shutter)")
        setExposure()
    }

    /// Auto once: let the camera measure for a moment, then keep what it found (manual from then on).
    func autoOnce() {
        autoExposure = true
        setExposure()
        publishMessage("Auto light")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.captureAutoValues()
            self.autoExposure = false
            self.setExposure()
        }
    }

    /// The camera's own current ISO and shutter, as manual values.
    private func captureAutoValues() {
        guard let dev = device else { return }
        let secs = CMTimeGetSeconds(dev.exposureDuration)
        if secs > 0 {
            let den = Int32((1 / secs).rounded())
            shutter = shutterDenominators.min { abs($0 - den) < abs($1 - den) } ?? shutter
        }
        iso = isoSteps.min { abs($0 - dev.iso) < abs($1 - dev.iso) } ?? iso
    }

    /// Next lens round (0.5, 1, 2, 4, 8), not while recording.
    func nextLens() {
        guard !recording, let i = lenses.firstIndex(of: lens), !lenses.isEmpty else { return }
        lens = lenses[(i + 1) % lenses.count]
        publishMessage(lens.label)
        reconfigure()
    }

    private func publishMessage(_ m: String) { publish { self.message = m } }

    // MARK: - recording

    func toggleRecord() {
        // Record during a time-lapse stops it early (the clip is kept).
        if timelapse != nil { stopTimelapse(); return }
        if photo.on { RecLog.w("photo pressed"); takePhoto(); return }
        queue.async {
            RecLog.w("record \(self.movie.isRecording ? "stop" : "start") pressed")
            if self.movie.isRecording { self.movie.stopRecording(); return }
            guard !self.starting else { return }
            // Start beep first, then record, so the beep isn't in the clip (as on Android).
            self.starting = true
            Beeper.shared.start()
            self.queue.asyncAfter(deadline: .now() + Beeper.startDelay) { self.starting = false; self.startRecording() }
        }
    }
    private var starting = false

    /// Photo mode: one RAW + HEIC pair, upright as the phone is held (Photo.swift).
    func takePhoto() {
        queue.async { self.photo.take(angle: self.rotation?.videoRotationAngleForHorizonLevelCapture) }
    }

    /// The Photo / Video switch. Not while recording. Main thread.
    func setPhotoMode(_ on: Bool) {
        guard !recording, timelapse == nil else { message = "Not while recording"; return }
        photo.on = on
        UserDefaults.standard.set(on, forKey: PhotoTaker.modeKey)
        RecLog.w(on ? "photo mode" : "video mode")
        queue.async { self.photo.queueOn = on; self.configure() }
    }

    private func startRecording() {
        guard problem == nil else {
            RecLog.w("NOT RECORDED: \(problem ?? "?")")
            Beeper.shared.alarm()
            publish { self.notRecorded = self.problem }
            return
        }
        let name = "CineMe_" + Camera.stamp.string(from: Date()) + ".mov"
        var folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let ext = resolveExternal() { folder = ext }
        let url = folder.appendingPathComponent(name)
        if let c = movie.connection(with: .video), let r = rotation {
            let a = r.videoRotationAngleForHorizonLevelCapture
            // ProRes RAW can't be rotated: its frames stay as the sensor reads them.
            if !codec.isRAW, c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
        }
        movie.metadata = Locator.shared.movieMetadata()
        let place = movie.metadata?.isEmpty == false ? ", with place" : ""
        RecLog.w("rec start \(name) (\(resolution.rawValue) \(fps) fps \(codec.rawValue)\(codec.isRAW ? "" : " " + look.rawValue)\(place))")
        // The clip's sound first: the meter's output goes if it would take it.
        SoundMeter.shared.checkBeforeRecording(session: session, movie: movie)
        movie.startRecording(to: url, recordingDelegate: self)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        clipStart = Date()
        publish { self.recording = true; self.recordStart = Date() }
    }

    /// iOS 18.2+: called instead of the one above, with the first buffer's time (for the timecode).
    @available(iOS 18.2, *)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime, from connections: [AVCaptureConnection]) {
        clipStart = ClipClock.wallTime(of: startPTS, clock: session.synchronizationClock)
        publish { self.recording = true; self.recordStart = Date() }
    }
    /// Wall-clock time of the clip's first frame (ClipFinish.swift).
    private var clipStart: Date?

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        publish { self.recording = false }
        let ext = externalURL   // the drive stays open until the clip is finished (ClipFinish)
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        guard ok, FileManager.default.fileExists(atPath: url.path) else {
            RecLog.w("NOT RECORDED \(url.lastPathComponent): \(error?.localizedDescription ?? "no file was written")")
            ext?.stopAccessingSecurityScopedResource()
            Beeper.shared.alarm()
            publish { self.notRecorded = error?.localizedDescription ?? "No file was written" }
            return
        }
        Beeper.shared.stop()
        RecLog.w("saved \(url.lastPathComponent), \(String(format: "%.1f", CMTimeGetSeconds(output.recordedDuration))) s")
        // Timecode track and anamorphic tag, in place, no re-encoding (ClipFinish.swift). Main thread after.
        ClipFinish.run(url, ClipFinish.plan(start: clipStart, fps: fps)) { note in
            ext?.stopAccessingSecurityScopedResource()
            if let n = note, !n.isEmpty { RecLog.w("\(url.lastPathComponent): \(n)") }
            if ext != nil { self.message = "Saved to \(self.externalName ?? "the drive")"; return }
            self.save(url)
        }
    }

    /// The app keeps its copy (the video manager plays it; Files > CineMe), out of the iCloud backup.
    /// A copy also goes to Photos unless "Copy to Photos" is off. (Also the time-lapse clips.)
    func save(_ url: URL) {
        var u = url; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? u.setResourceValues(rv)
        guard UserDefaults.standard.object(forKey: "toPhotos") as? Bool ?? true else { publishMessage("Video saved"); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.publish { self.message = "Video saved (Photos not allowed)" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { done, _ in
                self.publish { self.message = done ? "Video saved" : "Video saved (not in Photos)" }
            }
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    // MARK: - frames (tracking, time-lapse, picture aids)

    enum FrameUse { case tracking, timelapse, aids }

    /// Turns the frames output on or off for one use. [done] (main thread) gets nil when it worked,
    /// else what went wrong. iOS 16+ lets AVCaptureVideoDataOutput run beside AVCaptureMovieFileOutput
    /// (WWDC22 "Discover advancements in iOS camera capture"); ProRes is refused before this.
    /// Time-lapse takes the movie output out while it runs (it writes its own file), so any codec's
    /// format is safe; the movie output comes back after it.
    func useFrames(_ use: FrameUse, _ on: Bool, done: ((String?) -> Void)? = nil) {
        queue.async {
            let error = on ? self.addFrames(use) : nil
            if !on {
                self.framesFor.remove(use)
                self.session.beginConfiguration()
                if self.framesFor.isEmpty, self.session.outputs.contains(self.frames) { self.session.removeOutput(self.frames) }
                self.session.commitConfiguration()
                if use == .timelapse { self.configure() }   // the movie output and its codec again
                self.rotateFrames()
            }
            if let d = done { self.publish { d(error) } }
        }
    }

    /// On [queue].
    private func addFrames(_ use: FrameUse) -> String? {
        guard device != nil else {
            // The camera isn't open yet (launch): the picture aids' frames come with it (configure).
            if use == .aids { framesFor.insert(use); return nil }
            return "No camera"
        }
        framesFor.insert(use)
        session.beginConfiguration()
        if use == .timelapse, session.outputs.contains(movie) { session.removeOutput(movie) }
        var error: String? = nil
        var added = false
        if !session.outputs.contains(frames) {
            if attachFrames() { added = true } else { error = "The camera can't send frames with this format" }
        }
        session.commitConfiguration()
        // More than the camera hardware can do at this size and frame rate. (Frames already there for
        // another use passed this test when they came.)
        if error == nil, added || use == .timelapse, session.hardwareCost > 1 {
            session.beginConfiguration()
            session.removeOutput(frames)
            session.commitConfiguration()
            error = "Too much for the camera: try a lower frame rate or size"
        }
        if error != nil {
            framesFor.remove(use)
            if use == .timelapse { configure() }
            return error
        }
        rotateFrames()
        return nil
    }

    /// Adds the frames output, 8-bit 4:2:0: what Vision and the HEVC encoder take best (also from a
    /// 10-bit HDR or Log format). False if the camera can't. On [queue], inside a configuration.
    private func attachFrames() -> Bool {
        guard session.canAddOutput(frames) else { return false }
        frames.alwaysDiscardsLateVideoFrames = true
        frames.setSampleBufferDelegate(self, queue: framesQueue)
        session.addOutput(frames)
        let want = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if frames.availableVideoPixelFormatTypes.contains(want) {
            frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: want]
        }
        return true
    }

    /// Tracking and the picture aids lose their frames; [why] goes in the note ("it doesn't work
    /// with ProRes"). A time-lapse keeps them. On [queue].
    private func dropFrames(_ why: String) {
        let tracking = framesFor.contains(.tracking)
        let aids = framesFor.contains(.aids)
        framesFor.subtract([.tracking, .aids])
        if framesFor.isEmpty, session.outputs.contains(frames) { session.removeOutput(frames) }
        publish {
            if tracking { self.message = "Tracking off: \(why)"; self.onFramesDropped?() }
            if aids { self.onAidsDropped?(why) }
        }
    }

    /// Frames upright: as the screen shows them for tracking, level with the horizon for time-lapse. On [queue].
    private func rotateFrames() {
        guard let c = frames.connection(with: .video), let r = rotation else { return }
        let a = framesFor.contains(.timelapse) ? r.videoRotationAngleForHorizonLevelCapture : r.videoRotationAngleForHorizonLevelPreview
        if c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
    }

    /// Tracking: the frames turn with the screen (call when it turns).
    func refreshFrameRotation() { queue.async { if !self.framesFor.isEmpty { self.rotateFrames() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === frames, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if tlRun != nil { timelapseFrame(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
        onFrame?(pb)
        onAidFrame?(pb)
    }

    /// The phone's light flashes [times] (the arms trigger's answer), then [then] on the main thread.
    func blinkTorch(_ times: Int, then: (() -> Void)? = nil) {
        func set(_ on: Bool) {
            queue.async {
                guard let d = self.device, d.hasTorch, d.isTorchModeSupported(on ? .on : .off), (try? d.lockForConfiguration()) != nil else { return }
                d.torchMode = on ? .on : .off
                d.unlockForConfiguration()
            }
        }
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) { set(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6 + 0.3) { set(false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(times) * 0.6) { then?() }
    }

    // MARK: - external drive

    /// Remembers the folder chosen on a USB-C drive (a security-scoped bookmark).
    func setExternal(_ url: URL?) {
        guard let url = url else {
            UserDefaults.standard.removeObject(forKey: "extBookmark"); UserDefaults.standard.removeObject(forKey: "extName")
            externalName = nil
            return
        }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "extBookmark")
            UserDefaults.standard.set(url.lastPathComponent, forKey: "extName")
            externalName = url.lastPathComponent
        }
    }

    private func resolveExternal() -> URL? {
        externalURL = nil
        guard let data = UserDefaults.standard.data(forKey: "extBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            publish { self.message = "The drive isn't there: recording to the phone" }
            return nil
        }
        externalURL = url
        return url
    }
}

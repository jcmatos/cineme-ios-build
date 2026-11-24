import AVFoundation
import CoreLocation
import ImageIO
import Photos
import SwiftUI

// Photo mode (the Android app's PhotoSaver.kt + the photo half of CameraController / CameraScreen):
// each photo is an Apple ProRAW .dng and a HEIC (or JPEG) with the same name, like Android's
// RAW + JPEG pair. They stay in Documents/CineMe Photos (Files > On My iPhone > CineMe) and, unless
// "Copy to Photos" is off, go to Photos as one picture (the HEIC with the DNG as its RAW).
//
// Why photo mode builds its own session: AVCapturePhotoOutput may share a session with
// AVCaptureMovieFileOutput, but ProRAW and 48 MP need the photo formats (preset .photo), not the
// 4K / 10-bit / ProRes video formats Camera.configure() picks, and ProRes already fills the camera
// pipeline. So the photo output is only in the session in photo mode, and the movie output is out
// of it then (Apple's AVCam does the same). Camera.configure() calls configure() / finish() /
// remove() below; everything here that touches the session runs on Camera's queue.

/// The photo output, the photo settings and the files of the photo being taken.
final class PhotoTaker: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let output = AVCapturePhotoOutput()
    /// For messages ("Photo saved"). Set by Camera.start().
    weak var camera: Camera?

    /// Photo mode on (the Photo / Video switch). Main thread; kept between launches.
    @Published var on: Bool = UserDefaults.standard.bool(forKey: PhotoTaker.modeKey)
    /// A photo is being taken or saved: the shutter is grey and a second press waits.
    @Published var busy = false
    /// The same choice, as Camera's queue sees it (set there by Camera.setPhotoMode).
    var queueOn: Bool = UserDefaults.standard.bool(forKey: PhotoTaker.modeKey)
    /// finish() has run since the photo output went in (its limits are set). Camera's queue.
    private var ready = false

    static let modeKey = "photoMode"
    static let rawKey = "photoRAW"
    static let jpegKey = "photoJPEG"
    static let slowestKey = "photoSlowest"
    /// RAW (DNG) with each photo. On by default.
    static var wantsRaw: Bool { UserDefaults.standard.object(forKey: rawKey) as? Bool ?? true }
    /// JPEG instead of HEIC.
    static var wantsJPEG: Bool { UserDefaults.standard.bool(forKey: jpegKey) }
    /// Slowest shutter the camera's Auto may use, 1/n s (Android: 1/15 by default).
    static var slowestAuto: Int { UserDefaults.standard.object(forKey: slowestKey) as? Int ?? 15 }

    static let folderName = "CineMe Photos"
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName, isDirectory: true)
    }

    /// The photo on its way. Guarded by [lock]: set on Camera's queue, read in the delegate calls.
    private final class Pending {
        let name: String
        let ext: String
        let location: CLLocation?
        var processed: URL?
        var raw: URL?
        var error: String?
        init(name: String, ext: String, location: CLLocation?) { self.name = name; self.ext = ext; self.location = location }
    }
    private var pending: Pending?
    private let lock = NSLock()

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss_SSS"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    // MARK: - the session (Camera's queue)

    /// Photo mode's part of Camera.configure(), inside its begin / commit: the movie output out,
    /// preset .photo, the photo output in. False if the photo output can't be added.
    func configure(session: AVCaptureSession, movie: AVCaptureOutput) -> Bool {
        if session.outputs.contains(movie) { session.removeOutput(movie) }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        session.automaticallyConfiguresCaptureDeviceForWideColor = true   // P3 photos
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
        }
        ready = false
        return true
    }

    /// After that commit (the photo format is active now): full size, ProRAW, the lens crop and the
    /// slowest shutter for Auto. Returns the line for the top bar ("ProRAW + HEIC · 48 MP").
    func finish(session: AVCaptureSession, device: AVCaptureDevice, crop: CGFloat) -> String {
        session.beginConfiguration()
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        if let biggest = sizes.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            output.maxPhotoDimensions = biggest
        }
        output.maxPhotoQualityPrioritization = .quality
        // Enabling ProRAW reconfigures the camera (slow): only when it changes.
        if output.isAppleProRAWSupported, output.isAppleProRAWEnabled != PhotoTaker.wantsRaw {
            output.isAppleProRAWEnabled = PhotoTaker.wantsRaw
        }
        session.commitConfiguration()
        ready = true

        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = min(crop, device.activeFormat.videoMaxZoomFactor)
            let slow = CMTime(value: 1, timescale: CMTimeScale(PhotoTaker.slowestAuto))
            let f = device.activeFormat
            let auto = device.exposureMode == .continuousAutoExposure || device.exposureMode == .autoExpose
            if auto, CMTimeCompare(slow, f.minExposureDuration) >= 0, CMTimeCompare(slow, f.maxExposureDuration) <= 0 {
                device.activeMaxExposureDuration = slow
            }
            device.unlockForConfiguration()
        }

        let d = output.maxPhotoDimensions
        let mp = Int((Double(d.width) * Double(d.height) / 1e6).rounded())
        let raw = rawFormat() == nil ? "" : (output.isAppleProRAWEnabled ? "ProRAW + " : "RAW + ")
        let text = "\(raw)\(processedCodec() == .hevc ? "HEIC" : "JPEG")" + (mp > 0 ? " · \(mp) MP" : "")
        RecLog.w("photo mode: \(text)")
        return text
    }

    /// Video mode: the photo output out of the session. Inside Camera.configure()'s begin / commit.
    func remove(from session: AVCaptureSession) {
        if session.outputs.contains(output) { session.removeOutput(output) }
        ready = false
    }

    private func processedCodec() -> AVVideoCodecType {
        !PhotoTaker.wantsJPEG && output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
    }

    /// The RAW pixel format to ask for: ProRAW when it's on, else Bayer RAW; nil = no RAW.
    private func rawFormat() -> OSType? {
        guard PhotoTaker.wantsRaw else { return nil }
        let types = output.availableRawPhotoPixelFormatTypes
        if output.isAppleProRAWEnabled, let t = types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) { return t }
        return types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
    }

    // MARK: - taking one

    /// Takes a photo, upright for [angle] (the rotation coordinator's capture angle). Camera's queue.
    func take(angle: CGFloat?) {
        guard ready, output.connection(with: .video) != nil else { say("Photo mode isn't ready yet"); return }
        lock.lock()
        if pending != nil { lock.unlock(); return }   // one at a time (as on Android)
        let codec = processedCodec()
        let p = Pending(name: "CineMe_" + PhotoTaker.stamp.string(from: Date()), ext: codec == .hevc ? "heic" : "jpg",
                        location: Locator.shared.current())
        pending = p
        lock.unlock()

        let processed: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        let bayer = rawFormat() != nil && !output.isAppleProRAWEnabled
        if let raw = rawFormat() {
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: processed)
        } else {
            settings = AVCapturePhotoSettings(format: processed)
        }
        // Full size and best quality; Bayer RAW (only if ProRAW isn't offered) stays at the defaults.
        if !bayer {
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
        }
        if let a = angle, let c = output.connection(with: .video), c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
        DispatchQueue.main.async { self.busy = true }
        RecLog.w("photo \(p.name) (\(rawFormat() == nil ? "" : "RAW + ")\(p.ext)\(p.location == nil ? "" : ", with place"))")
        output.capturePhoto(with: settings, delegate: self)
    }

    private func current() -> Pending? { lock.lock(); defer { lock.unlock() }; return pending }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let p = current() else { return }
        if let e = error { lock.lock(); p.error = e.localizedDescription; lock.unlock(); return }
        let data = p.location == nil ? photo.fileDataRepresentation()
            : photo.fileDataRepresentation(with: PhotoPlace(p.location))
        guard let d = data else { lock.lock(); p.error = "No picture data"; lock.unlock(); return }
        let fm = FileManager.default
        try? fm.createDirectory(at: PhotoTaker.folder, withIntermediateDirectories: true)
        var url = PhotoTaker.folder.appendingPathComponent(p.name + "." + (photo.isRawPhoto ? "dng" : p.ext))
        do {
            try d.write(to: url, options: .atomic)
            // Out of the iCloud backup (as the clips): Photos has its own copy.
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? url.setResourceValues(rv)
            lock.lock()
            if photo.isRawPhoto { p.raw = url } else { p.processed = url }
            lock.unlock()
        } catch {
            lock.lock(); p.error = "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"; lock.unlock()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock()
        let p = pending
        pending = nil
        lock.unlock()
        DispatchQueue.main.async { self.busy = false }
        guard let p = p else { return }
        let why = error?.localizedDescription ?? p.error
        let files = [p.processed, p.raw].compactMap { $0 }
        if files.isEmpty {
            RecLog.w("PHOTO FAILED \(p.name): \(why ?? "no file")")
            say("Photo failed" + (why.map { ": \($0)" } ?? ""))
            return
        }
        if let w = why { RecLog.w("photo \(p.name): \(w)") }
        RecLog.w("photo saved: " + files.map { $0.lastPathComponent }.joined(separator: " + "))
        let what = p.raw != nil ? "RAW + \(p.ext == "heic" ? "HEIC" : "JPEG")" : (p.ext == "heic" ? "HEIC" : "JPEG")
        toPhotos(processed: p.processed, raw: p.raw, location: p.location, what: what)
    }

    /// Photos gets one picture: the HEIC / JPEG, with the DNG as its RAW (Apple's way for a RAW pair).
    private func toPhotos(processed: URL?, raw: URL?, location: CLLocation?, what: String) {
        guard UserDefaults.standard.object(forKey: "toPhotos") as? Bool ?? true else { say("Photo saved (\(what))"); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { self.say("Photo saved (\(what)), Photos not allowed"); return }
            PHPhotoLibrary.shared().performChanges({
                let r = PHAssetCreationRequest.forAsset()
                func options(_ u: URL) -> PHAssetResourceCreationOptions {
                    let o = PHAssetResourceCreationOptions()
                    o.originalFilename = u.lastPathComponent   // same name as in Files (the backup matches on it)
                    o.shouldMoveFile = false                   // the app keeps its copy
                    return o
                }
                if let main = processed ?? raw { r.addResource(with: .photo, fileURL: main, options: options(main)) }
                if let raw = raw, processed != nil { r.addResource(with: .alternatePhoto, fileURL: raw, options: options(raw)) }
                r.location = location
            }) { done, err in
                if !done { RecLog.w("photo not added to Photos: \(err?.localizedDescription ?? "?")") }
                self.say(done ? "Photo saved (\(what))" : "Photo saved (\(what)), not in Photos")
            }
        }
    }

    private func say(_ m: String) { DispatchQueue.main.async { self.camera?.message = m } }

    /// Screenshot runs (-shot photo): photo mode on, as an iPhone 18 Pro would show it.
    func fakeForShots(_ camera: Camera) {
        on = true
        camera.formatText = "ProRAW + HEIC · 48 MP"
        camera.message = "Photo saved (RAW + HEIC)"
    }
}

/// Puts the place (EXIF GPS) into the photo's file, HEIC / JPEG and DNG alike.
private final class PhotoPlace: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let location: CLLocation?
    init(_ l: CLLocation?) { location = l }
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let l = location else { return nil }
        var m = photo.metadata
        m[kCGImagePropertyGPSDictionary as String] = Locator.gps(l)
        return m
    }
}

// MARK: - on the camera screen

/// Android's Photo / Video capsule (CameraScreen.kt:1344): Plate, padding 12x5, 14sp, the chosen one
/// Ivory + brass mark, the other and the "/" Faint. Not while recording.
struct PhotoVideoSwitch: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var photo: PhotoTaker
    var body: some View {
        Button {
            if camera.recording || camera.timelapse != nil { camera.message = "Not while recording"; return }
            camera.setPhotoMode(!photo.on)
        } label: {
            HStack(spacing: 0) {
                Text("Photo").foregroundStyle(photo.on ? Color.ivory : Color.faint).brassMark(photo.on)
                Text("  /  ").foregroundStyle(Color.faint)
                Text("Video").foregroundStyle(!photo.on ? Color.ivory : Color.faint).brassMark(!photo.on)
            }
            .font(s.font(14))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, s(12)).padding(.vertical, s(5))
            .plateCapsule()
        }
        .buttonStyle(CinePressStyle())
    }
}

/// The shutter (CameraScreen.kt:1354): 86dp circle #1D1C1A, 2dp Edge border. Photo: a 58dp Ivory
/// disc (Faint while a photo is saved). Video: see RecordButton.
struct ShutterKey: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var photo: PhotoTaker
    @ObservedObject var mover: Mover
    var body: some View {
        if photo.on {
            Button { camera.toggleRecord() } label: {
                Circle().fill(photo.busy ? Color.faint : Color.ivory).frame(width: s(58), height: s(58))
                    .frame(width: s(86), height: s(86))
                    .plateCircle(fill: Color.shutterBody, border: Color.edge, borderWidth: 2)
            }
            .buttonStyle(CinePressStyle())
        } else {
            RecordButton(camera: camera, mover: mover)
        }
    }
}

/// Video: a 42dp dark well with a 26dp Red dot; recording: a 24dp Red square (corner 3dp). Blue
/// (and a blue well) while a gimbal move is set: recording also moves the gimbal.
struct RecordButton: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var mover: Mover
    var body: some View {
        let blue = mover.store.moveOn
        let fill = blue ? camBlue : Color.rec
        Button { camera.toggleRecord() } label: {
            ZStack {
                if camera.recording || camera.timelapse != nil {
                    cineRect(s(3)).fill(fill).frame(width: s(24), height: s(24))
                } else {
                    Circle().fill(fill).frame(width: s(26), height: s(26))
                        .frame(width: s(42), height: s(42))
                        .background(Circle().fill(blue ? Color.recWellBlue : Color.recWell))
                }
            }
            .frame(width: s(86), height: s(86))
            .plateCircle(fill: Color.shutterBody, border: Color.edge, borderWidth: 2)
        }
        .buttonStyle(CinePressStyle())
    }
}

/// Settings > Photo (Android settings rows: text options, brass mark on the chosen one).
struct PhotoSettingsSection: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @AppStorage(PhotoTaker.rawKey) private var raw = true
    @AppStorage(PhotoTaker.jpegKey) private var jpeg = false
    @AppStorage(PhotoTaker.slowestKey) private var slowest = 15
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneOnOff("RAW (Apple ProRAW .dng) with each photo", isOn: $raw)
            PaneOpt("Picture", [false, true], jpeg, title: { $0 ? "JPEG" : "HEIC" }) { jpeg = $0 }
            PaneOpt("Slowest shutter for Auto", [30, 15, 8], slowest, title: { "1/\($0)" }) { slowest = $0 }
            CineNote("Each photo is a .dng and a .heic (or .jpg) with the same name, in Files > On My iPhone > CineMe > CineMe Photos, and one picture in Photos. ProRAW is big: about 75 MB at 48 MP.")
        }
        .onChange(of: raw) { _, _ in if camera.photo.on { camera.reconfigure() } }
        .onChange(of: jpeg) { _, _ in if camera.photo.on { camera.reconfigure() } }
        .onChange(of: slowest) { _, _ in if camera.photo.on { camera.reconfigure() } }
    }
}

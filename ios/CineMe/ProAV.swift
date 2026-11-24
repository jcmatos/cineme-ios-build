import AVFoundation
import SwiftUI

// Sound, timecode and anamorphic: the choices (kept between launches) and the sound set-up.
//
// What a third-party app can do with the iPhone's sound (checked against Apple's SDK headers):
// - Mono / Stereo / Spatial: AVCaptureDeviceInput.multichannelAudioMode (.none / .stereo /
//   .firstOrderAmbisonics), iOS 18. Built-in mics only: ignored with a USB-C or Bluetooth mic.
//   Spatial with AVCaptureMovieFileOutput writes a stereo track (for old players) plus the
//   Spatial Audio (APAC, or PCM with ProRes) track and its metadata track.
// - Wind noise: AVCaptureDeviceInput.isWindNoiseRemovalEnabled, iOS 18. Only works when the mode
//   is Stereo or Spatial (header: "available when multichannelAudioMode is ... other than None").
// - Sound follows zoom: AVCaptureDeviceInput.isAudioZoomEnabled, iOS 26.4 (Stereo / Spatial only).
// - AirPods as a high quality mic: AVCaptureSession
//   .configuresApplicationAudioSessionForBluetoothHighQualityRecording, iOS 26.
// - Audio Mix (Standard, Cinematic, Studio, In-Frame...): NOT at capture time. It is applied when
//   playing or editing a Spatial Audio clip (Photos, or the Cinematic framework's
//   CNAssetSpatialAudioInfo / AUAudioMix, iOS 26). So: record Spatial, choose the mix later.

/// What the mics record.
enum SoundMode: String, CaseIterable, Identifiable {
    case mono = "Mono"
    case stereo = "Stereo"
    case spatial = "Spatial"
    var id: String { rawValue }

    var avMode: AVCaptureMultichannelAudioMode {
        switch self {
        case .mono: return .none
        case .stereo: return .stereo
        case .spatial: return .firstOrderAmbisonics
        }
    }
}

/// Anamorphic lens squeeze. The preview is shown wider by this much; the clip can be tagged too.
enum Squeeze: String, CaseIterable, Identifiable {
    case off = "Off"
    case x133 = "1.33x"
    case x15 = "1.5x"
    case x18 = "1.8x"
    case x2 = "2x"
    var id: String { rawValue }

    var factor: CGFloat {
        switch self {
        case .off: return 1
        case .x133: return 4.0 / 3
        case .x15: return 1.5
        case .x18: return 1.8
        case .x2: return 2
        }
    }

    /// Pixel aspect ratio for the file (horizontal : vertical spacing), nil = square pixels.
    var pixelAspect: (h: Int, v: Int)? {
        switch self {
        case .off: return nil
        case .x133: return (4, 3)
        case .x15: return (3, 2)
        case .x18: return (9, 5)
        case .x2: return (2, 1)
        }
    }
}

final class ProAV: ObservableObject {
    static let shared = ProAV()

    // Keys (also read on the camera queue, from UserDefaults, which is thread safe).
    static let kSound = "sound", kWind = "wind", kAudioZoom = "audioZoom", kAirPods = "airpodsMic"
    static let kTimecode = "timecode", kSqueeze = "squeeze", kTagSqueeze = "tagSqueeze"

    /// Screenshot runs: fake values, not saved.
    private var faking = false

    // MARK: choices

    @Published var sound: SoundMode = SoundMode(rawValue: UserDefaults.standard.string(forKey: ProAV.kSound) ?? "") ?? .stereo {
        didSet { save(sound.rawValue, ProAV.kSound) }
    }
    @Published var wind: Bool = ProAV.bool(ProAV.kWind, true) { didSet { save(wind, ProAV.kWind) } }
    /// iOS 26.4+: the sound narrows with the 2x / 4x / 8x lenses (Apple's default is on).
    @Published var audioZoom: Bool = ProAV.bool(ProAV.kAudioZoom, true) { didSet { save(audioZoom, ProAV.kAudioZoom) } }
    /// iOS 26+: AirPods may be chosen as the mic (high quality Bluetooth recording).
    @Published var airpods: Bool = ProAV.bool(ProAV.kAirPods, false) { didSet { save(airpods, ProAV.kAirPods) } }
    @Published var timecode: Bool = ProAV.bool(ProAV.kTimecode, false) { didSet { save(timecode, ProAV.kTimecode) } }
    @Published var squeeze: Squeeze = Squeeze(rawValue: UserDefaults.standard.string(forKey: ProAV.kSqueeze) ?? "") ?? .off {
        didSet { save(squeeze.rawValue, ProAV.kSqueeze) }
    }
    /// Write the pixel aspect ratio into the clip so editors show it wide.
    @Published var tagSqueeze: Bool = ProAV.bool(ProAV.kTagSqueeze, true) { didSet { save(tagSqueeze, ProAV.kTagSqueeze) } }

    // MARK: what the phone reports (main thread)

    /// nil = not known yet (camera not open): all choices shown.
    @Published var canStereo: Bool? = nil
    @Published var canSpatial: Bool? = nil
    @Published var canWind: Bool? = nil
    @Published var canAudioZoom = false
    /// What the clip really gets (Spatial not possible -> Stereo, and so on).
    @Published var soundNow: SoundMode? = nil
    /// The mic in use: "iPhone Microphone", "USB-C: RODE VideoMic", ...
    @Published var micName = "iPhone Microphone"
    @Published var micBuiltIn = true

    private var routeWatch: NSObjectProtocol?

    private init() {
        routeWatch = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.readMic()
        }
        readMic()
    }

    private static func bool(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    private func save(_ v: Any, _ k: String) { if !faking { UserDefaults.standard.set(v, forKey: k) } }

    /// The audio route's input: built-in, USB-C, wired headset or Bluetooth.
    func readMic() {
        guard Shot.screen == nil else { return }
        guard let p = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return }
        micBuiltIn = p.portType == .builtInMic
        switch p.portType {
        case .builtInMic: micName = "iPhone Microphone"
        case .usbAudio: micName = "USB-C: \(p.portName)"
        case .headsetMic: micName = "Wired: \(p.portName)"
        case .bluetoothHFP: micName = "Bluetooth: \(p.portName)"
        default: micName = p.portName
        }
    }

    // MARK: the sound set-up (camera queue)

    /// Sets the mic input for the chosen sound. On the camera queue, inside a session configuration
    /// (Camera.build), or wrapped in one (Camera.applySound). Every setter is guarded by its
    /// "supported" check: setting an unsupported value throws an exception.
    static func apply(to input: AVCaptureDeviceInput, session: AVCaptureSession) {
        let d = UserDefaults.standard
        let want = SoundMode(rawValue: d.string(forKey: kSound) ?? "") ?? .stereo
        let wind = bool(kWind, true), zoom = bool(kAudioZoom, true), pods = bool(kAirPods, false)

        let stereoOK = input.isMultichannelAudioModeSupported(.stereo)
        let spatialOK = input.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
        var mode = want
        if mode == .spatial && !spatialOK { mode = .stereo }
        if mode == .stereo && !stereoOK { mode = .mono }
        if input.multichannelAudioMode != mode.avMode { input.multichannelAudioMode = mode.avMode }

        let windOK = input.isWindNoiseRemovalSupported
        if windOK {
            // Only does anything in Stereo or Spatial.
            let on = wind && mode != .mono
            if input.isWindNoiseRemovalEnabled != on { input.isWindNoiseRemovalEnabled = on }
        }

        var zoomOK = false
        #if HAS_IOS27_SDK
        if #available(iOS 26.4, *) {
            zoomOK = input.isAudioZoomSupported
            if zoomOK, input.isAudioZoomEnabled != zoom { input.isAudioZoomEnabled = zoom }
        }
        if #available(iOS 26.0, *) {
            if session.configuresApplicationAudioSessionForBluetoothHighQualityRecording != pods {
                session.configuresApplicationAudioSessionForBluetoothHighQualityRecording = pods
            }
        }
        #endif
        _ = zoom; _ = pods   // (used only with the iOS 27 SDK)

        let z = zoomOK
        RecLog.w("sound \(mode.rawValue)\(mode != want ? " (wanted \(want.rawValue))" : "")\(windOK && wind && mode != .mono ? ", wind removal" : "")")
        DispatchQueue.main.async {
            let p = ProAV.shared
            p.canStereo = stereoOK; p.canSpatial = spatialOK; p.canWind = windOK; p.canAudioZoom = z
            p.soundNow = mode
            p.readMic()
        }
    }

    // MARK: screenshots

    /// Screenshot runs (no camera, no mic): what an iPhone 18 Pro would show. Nothing is saved.
    func fakeForShots(_ what: String) {
        faking = true
        canStereo = true; canSpatial = true; canWind = true; canAudioZoom = true
        micName = "iPhone Microphone"; micBuiltIn = true
        switch what {
        case "sound": sound = .spatial; soundNow = .spatial; wind = true; timecode = true; squeeze = .x18
        case "timecode": timecode = true
        case "anamorphic": squeeze = .x2
        default: break
        }
    }
}

import AVFoundation
import SwiftUI
import UIKit

/// Record signals, as on Android: one soft beep when recording starts, two quick ones when it stops,
/// and an "error" sound (two falling tones, twice) with a buzz when a take is lost. Or buzzes only,
/// or nothing (the Record signal setting). Safe to call from any thread.
final class Beeper: @unchecked Sendable {
    static let shared = Beeper()

    enum Signal: String, CaseIterable, Identifiable {
        case beeps = "Beeps", vibrate = "Vibrate", silent = "Silent"
        var id: String { rawValue }
    }

    var signal: Signal {
        get { Signal(rawValue: UserDefaults.standard.string(forKey: "recSignal") ?? "") ?? .beeps }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "recSignal") }
    }

    /// Start the recording this long after start(), so the beep isn't in the clip (Android: 120 + 40 ms).
    static let startDelay: TimeInterval = 0.16

    private static let rate = 48_000
    private var player: AVAudioPlayer?
    private lazy var startSound = Beeper.wav(Beeper.tone(1047, 0.12))
    private lazy var stopSound = Beeper.wav(Beeper.tone(1319, 0.07) + Beeper.silence(0.06) + Beeper.tone(1319, 0.07))
    private lazy var errorSound: Data = {
        let once = Beeper.tone(660, 0.16, buzzy: true) + Beeper.silence(0.04) + Beeper.tone(440, 0.28, buzzy: true)
        return Beeper.wav(once + Beeper.silence(0.25) + once)
    }()

    /// Recording starts: 1 beep (or 1 buzz).
    func start() { DispatchQueue.main.async { self.signalOut(self.startSound, buzzes: 1) } }

    /// Recording stopped: 2 beeps (or 2 buzzes).
    func stop() { DispatchQueue.main.async { self.signalOut(self.stopSound, buzzes: 2) } }

    /// A take was lost: the error sound and an error buzz (or the buzz only, or nothing).
    func alarm() {
        DispatchQueue.main.async {
            let s = self.signal
            if s == .silent { return }
            if s == .beeps { self.play(self.errorSound) }
            self.allowDuringRecording()
            MainActor.assumeIsolated { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    /// The red message was tapped away.
    func silence() { DispatchQueue.main.async { self.player?.stop() } }

    private func signalOut(_ sound: Data, buzzes: Int) {
        switch signal {
        case .beeps: play(sound)
        case .vibrate:
            allowDuringRecording()
            for n in 0..<buzzes {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(n)) {
                    MainActor.assumeIsolated { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                }
            }
        case .silent: break
        }
    }

    /// Uses the audio session as it is: the camera's sound set it up, and changing it here could
    /// cut the clip's sound. (RecordAudio.configure makes it play on the loud speaker.)
    private func play(_ data: Data) {
        allowDuringRecording()
        player?.stop()
        player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        player?.volume = 1
        player?.play()
    }

    /// iOS mutes haptics and system sounds while the mic records, unless told otherwise.
    private func allowDuringRecording() {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    // MARK: - the sounds (made here, no sound files)

    /// Sine at [hz] for [seconds], raised-cosine fade in/out (no click). [buzzy]: a little of the
    /// 2nd harmonic, so it reads as "error". Quiet (0.3) or medium (0.4) level, like Android.
    private static func tone(_ hz: Double, _ seconds: Double, buzzy: Bool = false) -> [Float] {
        let n = Int(Double(rate) * seconds)
        let fade = Int(Double(rate) * (buzzy ? 0.012 : 0.015))
        return (0..<n).map { i in
            let edge = min(i, n - 1 - i)
            let env = edge >= fade ? 1.0 : 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade))
            let x = 2 * Double.pi * hz * Double(i) / Double(rate)
            let v = buzzy ? 0.4 * env * (0.8 * sin(x) + 0.2 * sin(2 * x)) : 0.3 * env * sin(x)
            return Float(v)
        }
    }

    private static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(Double(rate) * seconds)) }

    /// 16-bit mono WAV in memory.
    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(bytes)
        for s in samples { put16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}

/// Optional: the camera's audio session set up by hand, so the beeps play on the loud speaker
/// (iOS's "play and record" plays on the small top speaker by default) and buzzes work while
/// recording. Use it in Camera, on its queue, before session.startRunning(), with
/// session.automaticallyConfiguresApplicationAudioSession = false.
enum RecordAudio {
    static func configure() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? s.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? s.setActive(true)
    }
}

/// Settings row: what recording start / stop sounds like.
struct RecordSignalPicker: View {
    @State private var signal = Beeper.shared.signal
    var body: some View {
        Picker("Record signal", selection: $signal) {
            ForEach(Beeper.Signal.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: signal) { _, s in
            Beeper.shared.signal = s
            Beeper.shared.start()   // a sample
        }
    }
}

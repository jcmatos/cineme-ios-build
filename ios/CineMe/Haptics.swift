import AVFoundation
import UIKit

/// A tiny buzz on every key press (the Android app's Haptics.kt): Settings > Screen > Vibrate on
/// taps, and how strong. Every Cine key calls it through CinePressStyle (Theme.swift); the drums,
/// level pill, G badge and the other tap gestures call it themselves.
@MainActor
enum Haptics {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    /// 1 (barely) .. 5 (firm).
    static var strength: Int { UserDefaults.standard.object(forKey: "hapticStrength") as? Int ?? 2 }
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func tap(force: Bool = false) {
        guard enabled || force else { return }
        // iOS mutes haptics while the mic runs (the camera's sound) unless told otherwise.
        let s = AVAudioSession.sharedInstance()
        if !s.allowHapticsAndSystemSoundsDuringRecording { try? s.setAllowHapticsAndSystemSoundsDuringRecording(true) }
        let amp: [CGFloat] = [0.2, 0.4, 0.6, 0.8, 1.0]
        generator.impactOccurred(intensity: amp[min(max(strength, 1), 5) - 1])
    }
}

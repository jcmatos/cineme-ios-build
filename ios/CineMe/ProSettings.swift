import AVFoundation
import AVKit
import SwiftUI
import UIKit

// Settings > Sound, Timecode and Anamorphic: the iPhone's own pages, in the Android settings look
// (PaneOpt / PaneOnOff rows, Dim notes). Shown by SettingsPanel.

/// Sound, Timecode and Anamorphic one under the other (old callers).
struct ProSections: View {
    @ObservedObject var camera: Camera
    @ObservedObject var pro = ProAV.shared

    var body: some View {
        SoundModeSection(pro: pro, onChange: { camera.applySound() })
        TimecodeSection(pro: pro, fps: camera.fps)
        AnamorphicSection(pro: pro)
    }
}

/// Settings > Sound: mono / stereo / spatial, wind, sound follows zoom, the microphone.
struct SoundModeSection: View {
    @ObservedObject var pro: ProAV
    let onChange: () -> Void

    /// Mono always; Stereo and Spatial when the phone has them (all while it isn't known yet).
    private var modes: [SoundMode] {
        SoundMode.allCases.filter { m in
            switch m {
            case .mono: return true
            case .stereo: return pro.canStereo ?? true
            case .spatial: return pro.canSpatial ?? true
            }
        }
    }

    private var ownMics: Bool { pro.sound != .mono && pro.micBuiltIn }

    var body: some View {
        PaneOpt("Sound", modes, pro.sound, title: { $0.rawValue }) { pro.sound = $0 }
            .onChange(of: pro.sound) { _, _ in onChange() }
        if pro.canWind ?? true {
            PaneOnOff("Wind noise reduction", isOn: $pro.wind, enabled: ownMics)
                .onChange(of: pro.wind) { _, _ in onChange() }
        }
        if pro.canAudioZoom {
            PaneOnOff("Sound follows zoom", isOn: $pro.audioZoom, enabled: ownMics)
                .onChange(of: pro.audioZoom) { _, _ in onChange() }
        }
        PaneValueRow("Microphone", pro.micName)
        MicChoice(pro: pro, onChange: onChange)
        CineNote(note)
    }

    private var note: String {
        var s = ""
        if let now = pro.soundNow, now != pro.sound { s += "This camera records \(now.rawValue) now. " }
        if !pro.micBuiltIn {
            s += "An external mic records as it is: Stereo, Spatial and wind reduction are only for the iPhone's own mics. "
        }
        s += "Spatial: Spatial Audio with a stereo copy for other players. The Audio Mix (Standard, In-Frame, Studio, Cinematic) "
        s += "is chosen later in Photos when editing the clip: iPhone apps can't record it in. Wind reduction works in Stereo and Spatial."
        return s
    }
}

/// External mics. USB-C and wired mics are used as soon as they are plugged in. iOS 26: AirPods
/// (high quality Bluetooth) and the system's microphone list.
struct MicChoice: View {
    @ObservedObject var pro: ProAV
    let onChange: () -> Void
    var body: some View {
        #if HAS_IOS27_SDK
        if #available(iOS 26.0, *) {
            PaneOnOff("AirPods as microphone", isOn: $pro.airpods)
                .onChange(of: pro.airpods) { _, _ in onChange() }
            MicPickerButton()
                .fixedSize()
                .padding(.top, Theme.settings(6))
        }
        #else
        EmptyView()
        #endif
    }
}

#if HAS_IOS27_SDK
/// "Choose microphone": the system's list of inputs (AVInputPickerInteraction, iOS 26), drawn as a
/// settings pill (Plate capsule, Jost 15sp Ivory, padding 13x7).
@available(iOS 26.0, *)
struct MicPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton {
        var c = UIButton.Configuration.plain()
        var t = AttributedString("Choose microphone")
        t.font = Jost.uiFont(Theme.settings(15))
        t.foregroundColor = UIColor(Color.ivory)
        c.attributedTitle = t
        c.cornerStyle = .capsule
        c.background.backgroundColor = UIColor(Color.plate)
        c.contentInsets = NSDirectionalEdgeInsets(top: Theme.settings(7), leading: Theme.settings(13),
                                                  bottom: Theme.settings(7), trailing: Theme.settings(13))
        let b = UIButton(configuration: c)
        let picker = AVInputPickerInteraction()
        b.addInteraction(picker)
        b.addAction(UIAction { _ in
            guard Shot.screen == nil else { return }
            picker.present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ProAV.shared.readMic() }
        }, for: .touchUpInside)
        return b
    }
    func updateUIView(_ b: UIButton, context: Context) {}
}
#endif

/// Settings > Timecode.
struct TimecodeSection: View {
    @ObservedObject var pro: ProAV
    let fps: Int
    var body: some View {
        PaneOnOff("Timecode (time of day)", isOn: $pro.timecode)
        let r = TimeOfDay.rate(fps)
        CineNote("Each clip gets a timecode track: the time of day of its first frame, at \(r) fps\(r != fps ? " (\(fps) fps clips use \(r))" : ""). " +
                 "Editors line up clips from cameras set to the same time. It's added just after the clip stops, without re-encoding. " +
                 "Not on drives that can't clone files (most USB-C drives).")
    }
}

/// Settings > Anamorphic.
struct AnamorphicSection: View {
    @ObservedObject var pro: ProAV
    var body: some View {
        PaneOpt("Anamorphic lens", Squeeze.allCases, pro.squeeze, title: { $0.rawValue }) { pro.squeeze = $0 }
        if pro.squeeze != .off {
            PaneOnOff("Tag clips for editors", isOn: $pro.tagSqueeze)
        }
        CineNote("The picture on screen is shown \(pro.squeeze == .off ? "wider by the lens squeeze" : pro.squeeze.rawValue + " wider") so it looks right. " +
                 "The clip is recorded squeezed, as the lens makes it. Tagged clips carry the pixel shape, so most editors show them wide by themselves; " +
                 "otherwise set the clip's pixel aspect in the editor.")
    }
}

/// Screenshot run "sound": the settings panel open at Sound (fake values set by ProAV.fakeForShots).
struct ProShotSheet: View {
    @ObservedObject var camera: Camera
    var body: some View {
        SettingsSheet(camera: camera, page: .sound)
    }
}

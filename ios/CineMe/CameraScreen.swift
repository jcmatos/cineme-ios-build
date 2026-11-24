import SwiftUI
import UniformTypeIdentifiers

/// The camera screen, laid out as the Android app's (CameraScreen.kt:167-416, screenshots in
/// DEVELOPMENT_FILES/android-ref): picture in the middle; top left histogram (and the sound meters);
/// top centre format, storage, battery; top right level, moves, time-lapse, record signal, gimbal;
/// bottom left mic, ISO and shutter drums, Auto; bottom centre WB, AF / MF, lenses; right Photo /
/// Video, record, play; bottom right Track and the gear. The pieces are in CamKit.swift.
/// Settings, gimbal, moves and time-lapse open over it (no sheets); the library is a full-screen cover.
struct CameraScreen: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var gimbal: Gimbal
    @State private var settings = false
    /// The settings page to open with (screenshot runs); nil = the panel's own choice.
    @State private var settingsPage: SettingsPage? = nil
    @State private var gimbalPanel = false
    @State private var wbOpen = false
    @State private var movesOpen = false
    @State private var timelapseOpen = false
    @State private var library = false
    @State private var voiceNote = false
    @State private var clearMove = false
    @State private var fontTest = false      // screenshot run "fonttest" only (Theme.swift)
    /// The focus ring (MF) in place of the drums.
    @State private var ring = false
    /// Auto pressed: "Measuring…" under the drums for a moment.
    @State private var measuring = false
    /// The status pill's height: the level pill, REC light and round keys copy it (Android statusHeight).
    @State private var statusHeight: CGFloat = Theme.cam(30)
    /// Level, gimbal moves and tracking (Level.swift, Moves.swift, Tracking.swift). Not observed here:
    /// the pieces that show them observe them, so the level's 30 readings a second don't redraw it all.
    let rig = Rig.shared
    /// Histogram, peaking and sharp areas (Aids.swift); not observed here either.
    let aids = PictureAids.shared

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let ins = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + ins.leading + ins.trailing, height: geo.size.height + ins.top + ins.bottom)
            // Android draws from the screen edge. Here the keys keep clear of the rounded corners, the
            // Dynamic Island and the home bar, but use part of the safe area's margin (it is wide in landscape).
            let side = landscape ? max(ins.leading, ins.trailing) * 0.55 : 0
            let grow = EdgeInsets(top: 0, leading: -(ins.leading - side), bottom: -(ins.bottom * 0.5), trailing: -(ins.trailing - side))
            ZStack {
                Color.black.ignoresSafeArea()
                picture.ignoresSafeArea()
                controls(landscape: landscape, width: full.width - 2 * side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(grow)
                CamMessages(camera: camera)
                AidsHook(camera: camera)
                overlays(landscape: landscape, full: full)
            }
            // Tracking's frames turn with the screen.
            .onChange(of: landscape) { _, _ in camera.refreshFrameRotation() }
        }
        .background(RemoteCatcher())   // remote and phone buttons (Remote.swift)
        .fullScreenCover(isPresented: $library, onDismiss: { if Shot.screen == nil { camera.start() } }) { LibraryView() }
        // Items marked for deletion on the backup site: their list comes up by itself (Backup.swift).
        .backupMarkedPrompt(recording: camera.recording)
        // A move set runs while recording; back to its start after.
        .onChange(of: camera.recording) { _, on in
            rig.recordingChanged(on, camera: camera)
            Backup.shared.recordingChanged(on)
        }
        .onChange(of: camera.autoFocus) { _, af in if af { ring = false } }
        .onAppear {
            rig.attach(camera: camera, gimbal: gimbal)
            // Not in screenshot runs: the simulator has no motion.
            if Shot.screen == nil { rig.level.start() } else { shotSetup() }
            // Screenshot runs only (Shot.swift).
            Shot.applyOrientation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openShot() }
        }
    }

    // MARK: - the picture

    /// The preview and everything drawn on it, shown wider together for an anamorphic lens.
    private var picture: some View {
        ZStack {
            PreviewView(camera: camera)
            ExposureLayer(aids: aids, maps: .shared)
            PeakingLayer(aids: aids, camera: camera)
            AnamorphicShotPattern()   // screenshot run "anamorphic" only (Anamorphic.swift)
            GuidesLayer()
            CamFocusLayer(camera: camera, aids: aids)
            TrackLayer(tracker: rig.tracker, camera: camera)
        }
        .modifier(Desqueeze())   // anamorphic lens: the picture shown wider (Anamorphic.swift)
    }

    // MARK: - the keys

    @ViewBuilder
    private func controls(landscape: Bool, width: CGFloat) -> some View {
        ZStack {
            // Top left: histogram (tap: parade, waveform), sound meters under it.
            VStack(alignment: .leading, spacing: s(6)) {
                HistogramCorner(aids: aids, landscape: landscape)
                MeterCorner(meter: .shared, aids: aids, photo: camera.photo, camera: camera, landscape: landscape)
            }
            .padding(.leading, s(landscape ? 16 : 12))
            .padding(.top, s(landscape ? 16 : 46))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Top centre: format, badges, storage, battery.
            CamStatusPill(camera: camera)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusHeight = $0 }
                .padding(.top, s(12))
                .padding(.horizontal, landscape ? s(260) : s(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Top right: level, moves, time-lapse, record signal, gimbal (portrait: under the status).
            CamTopRight(camera: camera, gimbal: gimbal, mover: rig.mover, backup: Backup.shared, level: rig.level,
                        statusHeight: statusHeight,
                        onClearMove: { clearMove = true },
                        onMoves: { movesOpen = true },
                        onTimelapse: timelapseTapped,
                        onGimbal: { gimbalPanel = true })
                .padding(.top, s(landscape ? 10 : 48))
                .padding(.trailing, s(10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Under the status: time-lapse running, arms trigger, zebras / false colour key.
            VStack(spacing: s(6)) {
                if let t = camera.timelapse { CamTimelapseBanner(t: t) }
                ArmsBanner(tracker: rig.tracker)
                ExposureBanner(aids: aids, maps: .shared)
            }
            .padding(.top, s(landscape ? 50 : 100))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Left: the drums (or the focus ring).
            wheels(landscape: landscape)
                .padding(.leading, s(landscape ? 16 : 12))
                .padding(.bottom, landscape ? s(14) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .bottomLeading : .leading)

            if landscape {
                bar(sliderWidth: min(380, width / Theme.camScale - 330), landscape: true)
                    .padding(.bottom, s(14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                record(portrait: false)
                    .padding(.trailing, s(18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            } else {
                VStack(spacing: s(12)) {
                    bar(sliderWidth: min(380, width / Theme.camScale - 270), landscape: false)
                    record(portrait: true)
                }
                .padding(.bottom, s(16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                CamTrackKey(tracker: rig.tracker, wide: false)
                    .padding(.leading, s(12)).padding(.bottom, s(16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            // Bottom right: Track (landscape) and the gear.
            HStack(spacing: s(10)) {
                if landscape { CamTrackKey(tracker: rig.tracker, wide: true) }
                CineRoundKey(enabled: !camera.recording, action: { settings.toggle() }) {
                    CineIcon(.gear, color: camera.recording ? Color.faint : Color.ivory)
                }
            }
            .padding(s(16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    @ViewBuilder
    private func wheels(landscape: Bool) -> some View {
        if ring && !camera.autoFocus {
            FocusRing(camera: camera, diameter: landscape ? 210 : 170) { ring = false }
        } else {
            CamWheels(camera: camera, portrait: !landscape,
                      onMic: {
                          if camera.recording { camera.message = "Not while recording" } else { voiceNote = true }
                      },
                      onRing: { camera.manualFocusHere(); ring = true },
                      measuring: $measuring)
        }
    }

    /// WB strip (when open) over the pills. Taps between the keys stay here (not focus on the picture).
    private func bar(sliderWidth: CGFloat, landscape: Bool) -> some View {
        VStack(spacing: s(6)) {
            if wbOpen { CamWBStrip(camera: camera, sliderWidth: max(120, sliderWidth)) }
            ViewThatFits(in: .horizontal) {
                CamControlBar(camera: camera, wbOpen: $wbOpen, ring: $ring)
                ScrollView(.horizontal, showsIndicators: false) {
                    CamControlBar(camera: camera, wbOpen: $wbOpen, ring: $ring).padding(.horizontal, s(8))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func record(portrait: Bool) -> some View {
        CamRecordControls(camera: camera, mover: rig.mover, portrait: portrait) {
            // The video manager. Not while filming: closing the camera would end the take.
            if camera.recording || camera.timelapse != nil { camera.message = "Not while recording"; return }
            camera.stop()
            library = true
        }
    }

    private func timelapseTapped() {
        if camera.timelapse != nil { camera.stopTimelapse() }
        else if camera.photo.on { camera.message = "Time-lapse is in Video mode" }
        else if camera.recording { camera.message = "Not while recording" }
        else { timelapseOpen = true }
    }

    // MARK: - over the screen

    @ViewBuilder
    private func overlays(landscape: Bool, full: CGSize) -> some View {
        if voiceNote { VoiceNoteView(camera: camera) { voiceNote = false } }
        if clearMove {
            CineConfirmDialog("Remove the gimbal move?", "Recording goes back to normal: the gimbal stays still.",
                              onYes: {
                                  clearMove = false
                                  rig.mover.store.moveOn = false
                                  camera.message = "Gimbal move removed"
                              },
                              onNo: { clearMove = false })
        }
        // The old-radio dialogs (Moves.swift, Timelapse.swift): they draw their own scrim.
        if movesOpen {
            MovesDialog(mover: rig.mover) { movesOpen = false }
        }
        if timelapseOpen {
            TimelapseDialog(mover: rig.mover, onStart: { plan, move in
                timelapseOpen = false
                rig.startTimelapse(plan, move, camera: camera)
            }, onClose: { timelapseOpen = false })
        }
        // Settings: the left 62% (portrait: the bottom 60%), the live picture stays in view; a tap
        // outside the panel closes it.
        if settings {
            ZStack(alignment: landscape ? .topLeading : .bottom) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { closeSettings() }
                SettingsPanel(camera: camera, gimbal: gimbal, page: settingsPage) { closeSettings() }
                    .frame(width: landscape ? full.width * 0.62 : full.width,
                           height: landscape ? full.height : full.height * 0.6)
            }
            // Flexible, not full.width: a frame wider than the safe area would widen the whole screen's
            // ZStack and push the camera keys off to the right.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        if gimbalPanel {
            GimbalPanel(gimbal: gimbal) { gimbalPanel = false }
        }
        if fontTest { ThemeSpecimen() }
    }

    private func closeSettings() {
        settings = false
        settingsPage = nil
    }

    // MARK: - screenshot runs (Shot.swift)

    /// Values as the Android reference shots show them (the simulator has no camera).
    private func shotSetup() {
        camera.autoExposure = false
        camera.iso = 80
        camera.shutter = 30
    }

    private func openShot() {
        switch Shot.screen {
        case "settings": settings = true
        case "library", "player": library = true
        case "note": voiceNote = true
        case "gimbal": gimbalPanel = true
        case "iso": break   // the drums are always there
        case "wb": wbOpen = true
        case "focus": camera.autoFocus = false; camera.focus = 0.6
        case "measuring": measuring = true; camera.autoExposure = true
        case "notrecorded": camera.notRecorded = "The camera sent no picture"
        case "movearmed": rig.mover.store.moveOn = true
        // Stage 3 (fake values: the simulator has no camera, gimbal or motion).
        case "level": rig.level.fakeForShots(1.8); camera.message = "Level"
        case "moves": rig.mover.fakeForShots(); movesOpen = true
        case "timelapse": rig.mover.fakeForShots(); timelapseOpen = true
        case "tracking": rig.tracker.fakeForShots(landscape: Shot.orientation != "portrait")
        // Picture aids and focus (fake frames).
        case "guides":
            UserDefaults.standard.set(true, forKey: "showGrid")
            UserDefaults.standard.set(SpiralCorner.bottomLeft.rawValue, forKey: "spiral")
        case "histogram": aids.fakeForShots("histogram", landscape: Shot.orientation != "portrait")
        case "peaking": aids.fakeForShots("peaking", landscape: Shot.orientation != "portrait")
        case "zebras", "falsecolour": ExposureMaps.shared.fakeForShots(Shot.screen ?? "", landscape: Shot.orientation != "portrait")
        case "meters": SoundMeter.shared.fakeForShots()
        case "focusring": camera.autoFocus = false; camera.focus = 0.35; ring = true
        // Stage 4 pro: sound, timecode, anamorphic (fake values, ProAV.swift).
        case "sound": ProAV.shared.fakeForShots("sound"); settingsPage = CameraScreen.shotPage("sound"); settings = true
        case "timecode": ProAV.shared.fakeForShots("timecode")
        case "anamorphic": ProAV.shared.fakeForShots("anamorphic")
        // Photo mode, help, backup, remote (fake values; Help, Backup and Remote are in Settings).
        case "photo": camera.photo.fakeForShots(camera)
        case "help", "remote": settingsPage = CameraScreen.shotPage(Shot.screen ?? ""); settings = true
        case "backup": Backup.shared.fakeForShots(); settingsPage = CameraScreen.shotPage("backup"); settings = true
        // Jost weights, palette, icons and shared keys (Theme.swift, Icons.swift).
        case "fonttest": fontTest = true
        // Any settings page: "set-screen", "set-gimbal", "set-tracking"… (the page's title, lowercased).
        case let p? where p.hasPrefix("set-"):
            settingsPage = SettingsPage.allCases.first { $0.rawValue.lowercased() == String(p.dropFirst(4)) }
            settings = true
        default: break
        }
    }

    /// The settings page a screenshot run opens. (SettingsPage is SettingsSheet.swift's; the case
    /// names are assumed here.)
    private static func shotPage(_ shot: String) -> SettingsPage? {
        switch shot {
        case "remote": return .remote
        case "backup": return .backup
        case "help": return .help
        case "sound": return .sound
        default: return nil
        }
    }
}

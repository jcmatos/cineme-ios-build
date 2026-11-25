import SwiftUI

@main
struct CineMeApp: App {
    @StateObject private var camera = Camera()
    @StateObject private var gimbal = Gimbal()
    @Environment(\.scenePhase) private var phase
    /// Starts the take log, and the backup's background uploads and runs (Backup.swift).
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate

    init() {
        // Screenshot runs: the simulator keeps the settings between shots, so each shot starts from
        // the defaults (one shot's fake settings must not show in the next).
        if Shot.screen != nil, let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(camera: camera, gimbal: gimbal)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    // Screenshot runs: no camera on the simulator, and its permission popup would cover the screen.
                    if Shot.screen == nil { camera.start() } else { camera.fakeForShots() }
                    // Gimbal keys, as on Android: record = start / stop; slider = brighter / darker;
                    // slider held: W = next lens, T = Auto light.
                    gimbal.onEvent = { e in
                        // The video manager is open: the keys drive the player, not the camera.
                        if LibraryRemote.shared.isOpen {
                            switch e {
                            case .shutter: LibraryRemote.shared.send(.click)
                            case .sliderW: LibraryRemote.shared.send(.forward)
                            case .sliderT: LibraryRemote.shared.send(.back)
                            case .holdW: LibraryRemote.shared.send(.fastForward)
                            case .holdT: LibraryRemote.shared.send(.fastBack)
                            case .release: LibraryRemote.shared.send(.letGo)
                            case .mode: break
                            }
                            return
                        }
                        switch e {
                        case .shutter: RecLog.w("gimbal record button"); camera.toggleRecord()
                        // W, T, W, T fast: tracking starts on the dotted square (Tracking.swift quickPush).
                        case .sliderW: if !Rig.shared.tracker.quickPush(true) { camera.exposureStep(1) }
                        case .sliderT: if !Rig.shared.tracker.quickPush(false) { camera.exposureStep(-1) }
                        case .holdW: camera.nextLens()
                        case .holdT: camera.autoOnce()
                        case .release, .mode: break
                        }
                    }
                    Remote.shared.attach(camera)
                    // Siri / Shortcuts drive this camera (SystemIntents.swift).
                    CameraLink.shared.camera = camera
                    // A Live Activity left from a take the app didn't see end (closed mid-take).
                    TakeActivityController.shared.endAll()
                    if Shot.screen == nil {
                        // Clips filmed from the lock screen, and the format for the lock screen camera.
                        LockedImport.run(camera)
                        CaptureContextSync.publish(camera)
                    }
                    Remote.shared.handlers[.level] = { Rig.shared.mover.toggleLevel() }
                    // Not in screenshot runs: the simulator has no Bluetooth (and would ask for it).
                    if Shot.screen == nil { gimbal.start() }
                    // The place for clips and photos, and the backup (not in screenshot runs).
                    if Shot.screen == nil { Locator.shared.start(); Backup.shared.schedule() }
                }
                .onChange(of: phase) { _, p in
                    if Shot.screen != nil { return }
                    if p == .active {
                        if !LibraryRemote.shared.isOpen { camera.start() }
                        LockedImport.run(camera)
                        Locator.shared.start()
                        Backup.shared.schedule()
                    } else if p == .background {
                        camera.stop()
                        Locator.shared.stop()
                        Backup.shared.scheduleBackground()
                    }
                }
                // The take's Live Activity (lock screen, Dynamic Island, Apple Watch).
                .onChange(of: camera.recording) { _, on in
                    if Shot.screen == nil { TakeActivityController.shared.recordingChanged(on, camera: camera) }
                }
                // New format chosen: the lock screen camera uses it next time.
                .onChange(of: camera.formatText) { _, _ in
                    if Shot.screen == nil { CaptureContextSync.publish(camera) }
                }
                // "Open CineMe" in the lock screen camera, after Face ID.
                .onContinueUserActivity(LockedImport.activityType) { _ in LockedImport.run(camera) }
        }
    }
}

// The Android app's colours, font, scale and shared keys: Theme.swift; its icons: Icons.swift.

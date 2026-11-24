import AppIntents
import Foundation

// Siri and Shortcuts: start / stop recording, take a photo, open CineMe. They run inside the app
// (no extension needed), so they also work when the extensions can't be installed.
// Siri by voice: Siri takes the microphone while it listens. Saying "stop recording" during a take is
// fine; starting from Siri is fine too (Siri is done listening before the take starts).

/// The camera the intents drive. CineMeApp sets it on launch (see the wiring notes).
@MainActor
final class CameraLink {
    static let shared = CameraLink()
    weak var camera: Camera?

    /// The camera once it's running. An intent can launch the app, and then it runs before the screen
    /// has appeared: wait for it (up to [seconds]).
    func ready(_ seconds: Double = 8) async -> Camera? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let c = camera, c.session.isRunning, !c.formatText.isEmpty { return c }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}

/// Waits until the camera has a new format text (after a photo / video switch), up to [seconds].
@MainActor
private func waitForNewFormat(_ camera: Camera, from old: String, seconds: Double = 3) async {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, camera.formatText == old {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    try? await Task.sleep(nanoseconds: 400_000_000)   // the outputs settle
}

struct OpenCineMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open CineMe"
    static let description = IntentDescription("Opens the CineMe camera.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult { .result() }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription("Opens CineMe and starts a take with the current format.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let camera = await CameraLink.shared.ready() else {
            return .result(dialog: "The camera isn't ready.")
        }
        if camera.recording || camera.timelapse != nil { return .result(dialog: "Already recording.") }
        if camera.photo.on {
            let old = camera.formatText
            camera.setPhotoMode(false)
            await waitForNewFormat(camera, from: old)
        }
        camera.toggleRecord()
        return .result(dialog: "Recording.")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description = IntentDescription("Stops the take (or the time-lapse) in CineMe.")
    // The camera only runs with CineMe on screen, so a take is only running then: no need to open it.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let camera = CameraLink.shared.camera, camera.recording || camera.timelapse != nil else {
            TakeActivityController.shared.endAll()
            return .result(dialog: "CineMe isn't recording.")
        }
        await TakeStopper.stop()
        return .result(dialog: "Stopped.")
    }
}

struct TakePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a photo"
    static let description = IntentDescription("Opens CineMe in Photo mode and takes a photo.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let camera = await CameraLink.shared.ready() else {
            return .result(dialog: "The camera isn't ready.")
        }
        if camera.recording || camera.timelapse != nil { return .result(dialog: "Not while recording.") }
        if !camera.photo.on {
            // Stays in Photo mode after: switching back now would cut the photo short.
            let old = camera.formatText
            camera.setPhotoMode(true)
            await waitForNewFormat(camera, from: old)
        }
        camera.takePhoto()
        return .result(dialog: "Photo taken.")
    }
}

/// Stops the take: the Stop intent, and the Stop key in the Live Activity (StopTakeIntent, TakeActivity.swift).
enum TakeStopper {
    @MainActor
    static func stop() async {
        guard let camera = CameraLink.shared.camera, camera.recording || camera.timelapse != nil else {
            // Nothing running (the app was closed mid-take): just clear the Live Activity.
            TakeActivityController.shared.endAll()
            return
        }
        if camera.timelapse != nil { camera.stopTimelapse() } else { camera.toggleRecord() }
    }
}

/// The phrases for Siri and the shortcuts shown in Shortcuts and Spotlight. Each phrase must name the app.
struct CineMeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: [
            "Start recording with \(.applicationName)",
            "Start recording in \(.applicationName)",
            "Record with \(.applicationName)",
            "Start a take in \(.applicationName)",
        ], shortTitle: "Start recording", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(), phrases: [
            "Stop recording with \(.applicationName)",
            "Stop recording in \(.applicationName)",
            "Stop the \(.applicationName) take",
        ], shortTitle: "Stop recording", systemImageName: "stop.circle")
        AppShortcut(intent: TakePhotoIntent(), phrases: [
            "Take a photo with \(.applicationName)",
            "Take a picture with \(.applicationName)",
        ], shortTitle: "Take a photo", systemImageName: "camera")
        AppShortcut(intent: OpenCineMeIntent(), phrases: [
            "Open the \(.applicationName) camera",
            "Film with \(.applicationName)",
        ], shortTitle: "Open CineMe", systemImageName: "video")
    }
}

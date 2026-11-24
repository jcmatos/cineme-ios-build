import ActivityKit
import AppIntents

// In two targets: CineMe (starts and ends the Live Activity) and CineMeWidgets (draws it).

/// The take on the lock screen and in the Dynamic Island: a running timer and the format.
struct TakeAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the take started: the timer counts from here by itself (no updates needed).
        var start: Date
        /// "4K30 HDR", "1080p240 SDR", "Time-lapse".
        var format: String
    }
}

/// The Stop key in the Live Activity. A LiveActivityIntent runs in the app's process, not the
/// widget's, so it can reach the camera. TakeStopper is the app's (SystemIntents.swift); the widget
/// target has an empty one (TakeStopperStub.swift) only so this file builds there.
struct StopTakeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the take"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await TakeStopper.stop()
        return .result()
    }
}

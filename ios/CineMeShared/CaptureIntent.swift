import AppIntents

// In three targets: CineMe (the app), CineMeCapture (lock screen camera) and CineMeWidgets (the control).
// iOS needs the same CameraCaptureIntent in all of them (Apple's AVCam sample does the same).

/// The camera choices the lock screen camera starts with. The app writes them (updateAppContext);
/// the capture extension reads them. It can't read the app's UserDefaults or an App Group, so this is
/// the only way in. Raw values of Lens, Resolution, Look, Codec (Formats.swift). Max 4 KB.
struct CaptureContext: Codable, Sendable, Equatable {
    var lens: String
    var resolution: String
    var fps: Int
    var look: String
    var codec: String
    var stabilization: Bool
}

/// Opens CineMe's camera: from the lock screen (the capture extension, no unlock), the Camera Control,
/// the Action button or the Control Center button (CaptureControl.swift). Unlocked, iOS opens the app.
struct CineMeCaptureIntent: CameraCaptureIntent {
    typealias AppContext = CaptureContext

    static let title: LocalizedStringResource = "Film with CineMe"
    static let description = IntentDescription("Opens the CineMe camera, also from the lock screen.")

    func perform() async throws -> some IntentResult {
        // iOS opens the camera itself; nothing to do here.
        .result()
    }
}

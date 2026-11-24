import AppIntents
import SwiftUI
import WidgetKit

/// The CineMe button for Control Center and the lock screen (and the Action button). It runs the
/// camera capture intent: locked, iOS opens the lock screen camera (CineMeCapture); unlocked, the app.
/// Having it (with the capture extension) is also what lists CineMe under
/// Settings > Camera > Camera Control > Launch Camera.
struct CaptureControl: ControlWidget {
    static let kind = "ca.channel13.cineme.capture-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: CineMeCaptureIntent()) {
                // Controls only draw SF Symbols.
                Label("CineMe", systemImage: "video.fill")
            }
        }
        .displayName("CineMe")
        .description("Film with CineMe, also from the lock screen.")
    }
}

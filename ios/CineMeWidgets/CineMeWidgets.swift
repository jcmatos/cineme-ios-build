import SwiftUI
import WidgetKit

// One widget extension for both: the CineMe control (Control Center, lock screen, Action button,
// and what makes CineMe a choice for the Camera Control) and the take's Live Activity.
// One extension, not two: with a free Apple ID every extension takes one of the 3 app slots.
// Sources: this folder + CineMeShared (both files).

@main
struct CineMeWidgets: WidgetBundle {
    var body: some Widget {
        CaptureControl()
        TakeLiveActivity()
    }
}

/// The app's colours (CineMeApp.swift isn't in this target).
enum Palette {
    static let ivory = Color(red: 0.93, green: 0.90, blue: 0.84)
    static let dim = Color(red: 0.55, green: 0.53, blue: 0.48)
    static let rec = Color(red: 0.84, green: 0.15, blue: 0.12)
}

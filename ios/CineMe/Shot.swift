import SwiftUI
import UIKit

/// Screenshot runs on GitHub's Mac simulator (.github/workflows/ios-shots.yml): the app is launched
/// with `-shot <screen> -orient <landscape|portrait>` and opens that screen by itself, so each
/// screen can be checked from Windows. Screens: camera, settings, gimbal, iso, wb, focus, library,
/// player, remote, note, level, moves, timelapse, tracking, guides, histogram, peaking, focusring,
/// help, photo (photo mode), backup (with made-up items marked for deletion).
/// Normal launches have no -shot and nothing here changes anything.
enum Shot {
    static var screen: String? { value(after: "-shot") }
    static var orientation: String? { value(after: "-orient") }

    private static func value(after flag: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// Turns the simulator window (there's no rotate command for it).
    static func applyOrientation() {
        guard let o = orientation,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = o == "portrait" ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

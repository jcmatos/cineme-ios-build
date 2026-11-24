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

/// Screenshot runs only: a still room photo where the camera picture would be (the simulator has no
/// camera), so the plates and keys show as they do over a real picture. The shots workflow adds the
/// image (ShotBackdrop.jpg); normal builds don't have it, and then this draws nothing.
struct ShotBackdrop: View {
    private static let image: UIImage? = Shot.screen == nil ? nil :
        Bundle.main.path(forResource: "ShotBackdrop", ofType: "jpg").flatMap { UIImage(contentsOfFile: $0) }

    var body: some View {
        GeometryReader { geo in
            if let im = Self.image {
                let landscape = geo.size.width > geo.size.height
                let r: CGFloat = landscape ? 16.0 / 9.0 : 9.0 / 16.0
                let w = min(geo.size.width, geo.size.height * r)
                Image(uiImage: im).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: w, height: w / r).clipped()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

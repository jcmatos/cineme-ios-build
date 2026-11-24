import ActivityKit
import Foundation
import LockedCameraCapture

// The app's side of the system pieces: the Live Activity while recording, the clips filmed from the
// lock screen, and the camera choices handed to the lock screen camera. All harmless when the
// extensions aren't installed (the "lite" .ipa): nothing shows, nothing is found.

/// The take's Live Activity (TakeAttributes, drawn by CineMeWidgets). The timer runs by itself.
/// Where it shows: the Dynamic Island and lock screen when CineMe isn't the app on screen, the pulled
/// down Notification Center, and the Apple Watch Smart Stack. (iOS stops the camera when CineMe goes
/// to the background, so a take that's still running is mostly seen on the Watch and in the Island
/// only for a moment.)
@MainActor
final class TakeActivityController {
    static let shared = TakeActivityController()
    private var activity: Activity<TakeAttributes>?

    /// Call when camera.recording changes (wiring notes: CineMeApp).
    func recordingChanged(_ on: Bool, camera: Camera) {
        if on { begin(camera) } else { endAll() }
    }

    private func begin(_ camera: Camera) {
        endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = TakeAttributes.ContentState(start: camera.recordStart, format: Self.shortFormat(camera))
        activity = try? Activity.request(attributes: TakeAttributes(),
                                         content: ActivityContent(state: state, staleDate: nil),
                                         pushType: nil)
    }

    /// Ends this take's Live Activity, and any left from a take the app didn't see end.
    func endAll() {
        activity = nil
        let all = Activity<TakeAttributes>.activities
        guard !all.isEmpty else { return }
        Task {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// "4K30 HDR (Dolby Vision) · HEVC" -> "4K30 HDR". Time-lapse says so.
    static func shortFormat(_ camera: Camera) -> String {
        if camera.timelapse != nil { return "Time-lapse" }
        let first = camera.formatText.components(separatedBy: " · ").first ?? camera.formatText
        return first.replacingOccurrences(of: " (Dolby Vision)", with: "")
    }
}

/// Clips filmed from the lock screen (CineMeCapture) wait in their session folders until the app
/// takes them: into Documents (the video manager and Files > CineMe), then Photos as usual
/// (camera.save), then the session folder is let go. Runs on launch and each time the app comes up.
@MainActor
enum LockedImport {
    private static var busy = false
    /// What the lock screen camera's "Open CineMe" opens the app with (so CineMeApp needn't import LockedCameraCapture).
    static let activityType = NSUserActivityTypeLockedCameraCapture

    static func run(_ camera: Camera) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            for dir in LockedCameraCaptureManager.shared.sessionContentURLs {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                var allMoved = true
                for f in files where f.pathExtension.lowercased() == "mov" {
                    let dest = freeName(f.lastPathComponent, in: docs)
                    do {
                        try fm.moveItem(at: f, to: dest)
                    } catch {
                        // A move across volumes can fail where a copy works.
                        do { try fm.copyItem(at: f, to: dest) } catch {
                            RecLog.w("lock screen clip \(f.lastPathComponent) NOT imported: \(error.localizedDescription)")
                            allMoved = false
                            continue
                        }
                    }
                    RecLog.w("lock screen clip imported: \(dest.lastPathComponent)")
                    camera.save(dest)
                }
                // Only let the folder go once every clip is safe.
                if allMoved { try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: dir) }
            }
        }
    }

    /// CineMe_20261122_183000.mov, or CineMe_20261122_183000_2.mov if that's taken.
    private static func freeName(_ name: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)_\(n).mov")
            n += 1
        }
        return url
    }
}

/// Hands the current video choices to the lock screen camera (CineMeCaptureIntent's app context).
@MainActor
enum CaptureContextSync {
    private static var last: CaptureContext?

    static func publish(_ camera: Camera) {
        let ctx = CaptureContext(lens: camera.lens.rawValue, resolution: camera.resolution.rawValue, fps: camera.fps,
                                 look: camera.look.rawValue, codec: camera.codec.rawValue,
                                 stabilization: camera.stabilization)
        guard ctx != last else { return }
        last = ctx
        Task { try? await CineMeCaptureIntent.updateAppContext(ctx) }
    }
}

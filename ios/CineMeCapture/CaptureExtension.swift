import ExtensionKit
import Foundation
import LockedCameraCapture
import SwiftUI

// The lock screen camera: a separate small program iOS runs over the lock screen, without unlocking,
// from the Camera Control, the Action button, or the CineMe button in Control Center / on the lock
// screen. It only films video, with the format chosen in the app. It can't see the app's files or
// settings: the clips go into the session folder iOS gives it, and the app takes them from there
// (LockedImport in SystemHooks.swift). Sources: this folder + CineMeShared/CaptureIntent.swift +
// CineMe/Formats.swift.

@main
struct CineMeCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCameraView(session: session)
        }
    }
}

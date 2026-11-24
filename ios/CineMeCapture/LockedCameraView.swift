import AVFoundation
import AVKit
import LockedCameraCapture
import SwiftUI

/// The lock screen camera's screen: the picture, the format and the take timer on top, and the
/// record key. The Camera Control and the volume keys also start and stop a take. "Open CineMe"
/// asks for Face ID and opens the full app, which then takes the clips.
/// Portrait only (Info.plist): the clips are still level whichever way the phone is held.
struct LockedCameraView: View {
    let session: LockedCameraCaptureSession
    @StateObject private var camera: LockedCamera
    @Environment(\.scenePhase) private var phase

    init(session: LockedCameraCaptureSession) {
        self.session = session
        _camera = StateObject(wrappedValue: LockedCamera(folder: session.sessionContentURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LockedPreview(camera: camera).ignoresSafeArea()
            VStack(spacing: 12) {
                topBar
                if let p = camera.problem {
                    Text(p).font(.system(size: 15)).foregroundStyle(Palette.ivory)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Palette.rec.opacity(0.85)))
                }
                if camera.denied {
                    Text("Open CineMe once to allow the camera.").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ivory).padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.plate))
                }
                Spacer()
                HStack(alignment: .center) {
                    Button { openApp() } label: {
                        Text("Open CineMe").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ivory)
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(Capsule().fill(Palette.plate))
                    }
                    .disabled(camera.recording)
                    .opacity(camera.recording ? 0.4 : 1)
                    Spacer()
                    recordKey
                    Spacer()
                    Text(camera.saved == 0 ? " " : "\(camera.saved) saved")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ivory)
                        .frame(width: 110, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .padding(.top, 8)
        }
        .statusBarHidden(true)
        // Camera Control press, volume up / down: start / stop.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { tap(); camera.toggleRecord() }
        }
        .task {
            // The app's choices (nil until the app has run once with this version): CaptureContextSync.
            let ctx: CaptureContext? = try? await CineMeCaptureIntent.appContext
            camera.start(ctx)
        }
        .onChange(of: phase) { _, p in
            // Leaving (screen off, swiped away): the take ends and is kept.
            if p == .background { camera.stop() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            if camera.recording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = max(0, Int(Date().timeIntervalSince(camera.recordStart)))
                    Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "circle.fill")
                        .foregroundStyle(Palette.rec)
                }
            }
            Text(camera.formatText.isEmpty ? "CineMe" : camera.formatText).lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Palette.ivory)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Capsule().fill(Palette.plate))
    }

    private var recordKey: some View {
        Button { tap(); camera.toggleRecord() } label: {
            ZStack {
                Circle().stroke(Palette.ivory.opacity(0.7), lineWidth: 3).frame(width: 78, height: 78)
                if camera.recording {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.rec).frame(width: 30, height: 30)
                } else {
                    Circle().fill(Palette.rec).frame(width: 58, height: 58)
                }
            }
        }
        .disabled(camera.denied)
    }

    private func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    /// Face ID, then the full app (it imports the clips on launch).
    private func openApp() {
        camera.stop()
        let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
        Task { try? await session.openApplication(for: activity) }
    }
}

/// The camera picture, filling the screen with the whole frame shown.
struct LockedPreview: UIViewRepresentable {
    let camera: LockedCamera

    func makeUIView(context: Context) -> LockedPreviewView {
        let v = LockedPreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = camera.session
        v.previewLayer.videoGravity = .resizeAspect
        camera.previewLayer = v.previewLayer
        return v
    }

    func updateUIView(_ uiView: LockedPreviewView, context: Context) {}
}

final class LockedPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// The app's colours (CineMeApp.swift isn't in this target).
enum Palette {
    static let ivory = Color(red: 0.93, green: 0.90, blue: 0.84)
    static let rec = Color(red: 0.84, green: 0.15, blue: 0.12)
    static let plate = Color.black.opacity(0.66)
}

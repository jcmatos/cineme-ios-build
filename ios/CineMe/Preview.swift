import AVFoundation
import SwiftUI
import UIKit

/// The live picture. Keeps it level as the phone turns (RotationCoordinator), and tap = focus there.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint) -> Void)?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var watch: NSKeyValueObservation?

    func follow(_ device: AVCaptureDevice?) {
        guard let device = device, coordinator?.device != device else { return }
        let c = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        coordinator = c
        apply(c.videoRotationAngleForHorizonLevelPreview)
        watch = c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.apply(c.videoRotationAngleForHorizonLevelPreview) }
        }
    }

    private func apply(_ angle: CGFloat) {
        if let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = previewLayer.captureDevicePointConverted(fromLayerPoint: g.location(in: self))
        onTap?(p)
    }
}

struct PreviewView: UIViewRepresentable {
    @ObservedObject var camera: Camera

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = camera.session
        camera.previewLayer = v.previewLayer
        v.onTap = { camera.focus(at: $0) }
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        v.follow(camera.device)
    }
}

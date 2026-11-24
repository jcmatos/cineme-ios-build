import CoreMotion
import SwiftUI
import UIKit

/// The phone's own angles, from CoreMotion (the Android app's gravity and turn sensors):
///  - [tilt]: the horizon on screen, degrees (+ = its right side higher), nil = pointing at floor or sky;
///  - [pitch]: camera up / down from level, degrees (+ = up);
///  - [heading]: degrees turned right since [zeroHeading] (pan moves count from there).
/// Updates on the main thread.
final class Level: ObservableObject {
    @Published private(set) var tilt: Double? = nil
    private(set) var pitch: Double? = nil
    private(set) var heading: Double = 0

    private let motion = CMMotionManager()
    private var last: TimeInterval = 0
    private var fake = false

    func start() {
        #if targetEnvironment(simulator)
        // No motion in the simulator: show the pill level (0.0°, green) as a phone held level would.
        if !motion.isDeviceMotionAvailable { tilt = 0; pitch = 0; return }
        #endif
        guard !fake, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self = self, let m = m else { return }
            self.update(m)
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }

    /// Screenshot runs: the simulator has no motion.
    func fakeForShots(_ t: Double) { fake = true; tilt = t; pitch = 0 }

    /// Pan counts from where the camera looks now.
    func zeroHeading() { heading = 0 }

    private func update(_ m: CMDeviceMotion) {
        let g = m.gravity   // in g, device axes (portrait: x right, y up, z out of the screen)
        // "Up" in phone coordinates is the opposite of gravity; turned into screen coordinates
        // (x right, y up) by how the screen is turned, as LevelPill.kt does.
        let ux = -g.x, uy = -g.y
        let (sx, sy): (Double, Double)
        switch Level.interfaceOrientation() {
        case .landscapeRight: (sx, sy) = (-uy, ux)   // top of the phone on the left (Android ROTATION_90)
        case .landscapeLeft: (sx, sy) = (uy, -ux)    // ROTATION_270
        case .portraitUpsideDown: (sx, sy) = (-ux, -uy)
        default: (sx, sy) = (ux, uy)
        }
        // Mostly flat (looking down or up): the horizon angle means nothing (Android: under 3 m/s²).
        if (sx * sx + sy * sy).squareRoot() < 0.3 {
            if tilt != nil { tilt = nil }
        } else {
            let a = -atan2(sx, sy) * 180 / .pi
            // Smoothed, so the water doesn't shake.
            tilt = tilt.map { $0 + (a - $0) * 0.2 } ?? a
        }
        // Camera on the back: pointing up = screen facing down = gravity along +z.
        pitch = atan2(g.z, (g.x * g.x + g.y * g.y).squareRoot()) * 180 / .pi
        // Heading: the turn rate round the vertical (rotation rate · up), added up. + = turning right.
        // (No compass: only how far it turned since the move was set matters.)
        if last > 0 {
            let dt = min(0.2, m.timestamp - last)
            let r = m.rotationRate
            let aroundUp = r.x * ux + r.y * uy + r.z * -g.z   // rad/s, + = counter-clockwise from above = left
            heading -= aroundUp * dt * 180 / .pi
        }
        last = m.timestamp
    }

    static func interfaceOrientation() -> UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.effectiveGeometry.interfaceOrientation ?? .portrait
    }
}

/// Spirit level as a pill of water (LevelPill.kt): 62dp x the status pill's height, Plate capsule,
/// 1dp Brass border while the gimbal levels. Level = the bottom half green. Tilt the phone and the
/// water stays flat while the pill turns, so its surface slopes; green <= 1°, yellow <= 3°, else
/// red, Dim with no reading. Text 13sp w500 Ivory. (Over a black background only the water shows:
/// the Plate's top half is black on black, as on Android.)
/// Tap = the gimbal levels the horizon; long press = the moves.
struct LevelPill: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var level: Level
    @ObservedObject var mover: Mover
    /// Points: the status pill's measured height.
    let height: CGFloat
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        let t = level.tilt
        let off = abs(t ?? 0)
        let color: Color = t == nil ? Color.dim : off <= 1 ? Color.okGreen : off <= 3 ? Color.levelYellow : Color.rec
        ZStack {
            Canvas { ctx, size in
                let w = size.width, h = size.height
                // Surface through the middle, sloped by the tilt (capped so it stays inside the pill).
                let slope = t.map { tan(max(-30, min(30, $0)) * .pi / 180) } ?? 0
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h / 2 + w / 2 * slope))
                p.addLine(to: CGPoint(x: w, y: h / 2 - w / 2 * slope))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(0.75)))
            }
            Text(t == nil ? "–" : String(format: "%.1f°", off))
                .font(s.font(13, .medium)).foregroundStyle(Color.ivory)
        }
        .frame(width: s(62), height: height)
        .plateCapsule(border: mover.running ? Color.brass : nil)
        .onTapGesture { Haptics.tap(); onTap() }
        .onLongPressGesture { Haptics.tap(); onLongPress() }
    }
}

import SwiftUI

/// Focus ring (MF), the Android app's FocusRing.kt: turn it round and round like a lens ring, no
/// end to the stroke as on the drum. Clockwise = farther, anticlockwise = closer; about 4 turns
/// from closest to farthest. The box is the diameter + 20dp; X (34dp) top right goes back to the drums.
/// (iOS gives the lens position 0..1, not metres: the middle shows it as 0.00 near .. 1.00 far.)
struct FocusRing: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    /// Android dp: 210 landscape, 170 portrait.
    let diameter: CGFloat
    let onClose: () -> Void
    @State private var turn: Double = 0
    @State private var last: Double? = nil
    @State private var held = false

    /// Degrees of turn for the whole focus range.
    private static let fullTurn = 1440.0

    var body: some View {
        let d = s(diameter)
        let r = d / 2
        let f = camera.focus
        ZStack(alignment: .topTrailing) {
            ZStack {
                Canvas { ctx, size in FocusRing.ring(&ctx, size, turn: turn, held: held, px: s(1)) }
                Text("Closer").font(s.font(12)).tracking(s.tracking(0.06, sp: 12)).foregroundStyle(Color.ivory)
                    .offset(x: -r * 0.42, y: -r * 0.24)
                Text("Far").font(s.font(12)).tracking(s.tracking(0.06, sp: 12)).foregroundStyle(Color.ivory)
                    .offset(x: r * 0.42, y: -r * 0.24)
                VStack(spacing: 0) {
                    Text("Focus").font(s.font(12)).tracking(s.tracking(0.08, sp: 12)).foregroundStyle(Color.dim)
                    Text(String(format: "%.2f", f))
                        .font(s.font(diameter < 180 ? 22 : 26, .medium)).foregroundStyle(Color.ivory)
                        .monospacedDigit().lineLimit(1)
                    if f <= 0.001 || f >= 0.999 {
                        Text(f >= 0.999 ? "farthest" : "closest").font(s.font(11)).foregroundStyle(Color.faint)
                    }
                }
                .offset(y: r * 0.12)
                .allowsHitTesting(false)
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in drag(v.location) }
                .onEnded { _ in held = false; last = nil })
            .frame(width: d + s(20), height: d + s(20))
            CineCloseKey(size: 34, cross: 13, action: onClose)
        }
        .frame(width: d + s(20), height: d + s(20))
    }

    private func drag(_ at: CGPoint) {
        held = true
        let half = s(diameter) / 2
        let dx = Double(at.x - half), dy = Double(at.y - half)
        // Near the middle the angle jumps about: ignore it there.
        guard (dx * dx + dy * dy).squareRoot() >= Double(half * 2) * 0.15 else { last = nil; return }
        // Screen y points down, so the angle grows clockwise.
        let a = atan2(dy, dx) * 180 / .pi
        defer { last = a }
        guard let l = last else { return }
        var da = a - l
        if da > 180 { da -= 360 }
        if da < -180 { da += 360 }
        turn += da
        if camera.autoFocus { camera.manualFocusHere() }
        let before = camera.focus
        let f = min(max(before + Float(da / FocusRing.fullTurn), 0), 1)
        guard f != before else { return }
        camera.focus = f
        camera.setFocus()
        // A tick at either end.
        if f == 0 || f == 1 { Haptics.tap() }
    }

    /// The ring: a knurled band that turns with the finger, a red index on top, the two direction
    /// arrows inside.
    static func ring(_ ctx: inout GraphicsContext, _ size: CGSize, turn: Double, held: Bool, px: CGFloat) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let band = r * 0.24
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
        ctx.fill(circle(r), with: .color(Color.drum))
        ctx.stroke(circle(r - 0.5 * px), with: .color(held ? Color.brass : Color.edge), lineWidth: px)
        ctx.stroke(circle(r - band), with: .color(Color.edge), lineWidth: px)
        // Knurl: short ridges across the band every 6°; every 90° a yellow one, so the turning shows.
        var plain = Path(), marks = Path()
        for step in 0..<60 {
            let a = Double(step * 6)
            let t = (a + turn) * .pi / 180
            let ct = CGFloat(cos(t)), st = CGFloat(sin(t))
            let from = CGPoint(x: c.x + ct * (r - band * 0.9), y: c.y + st * (r - band * 0.9))
            let to = CGPoint(x: c.x + ct * (r - band * 0.1), y: c.y + st * (r - band * 0.1))
            // 30°, 120°, 210°, 300°: off the red index at the start.
            if Int(a + 60) % 90 == 0 { marks.move(to: from); marks.addLine(to: to) } else { plain.move(to: from); plain.addLine(to: to) }
        }
        ctx.stroke(plain, with: .color(Color.ringRidge), style: StrokeStyle(lineWidth: 1.5 * px, lineCap: .round))
        ctx.stroke(marks, with: .color(Color.ringMarker), style: StrokeStyle(lineWidth: 3.5 * px, lineCap: .round))
        // Red index at the top of the band (fixed, like on a lens).
        var index = Path()
        let iy = c.y - r + px
        index.move(to: CGPoint(x: c.x - 6 * px, y: iy)); index.addLine(to: CGPoint(x: c.x + 6 * px, y: iy)); index.addLine(to: CGPoint(x: c.x, y: iy + 10 * px))
        index.closeSubpath()
        ctx.fill(index, with: .color(Color.rec))
        // Arrows inside the band: anticlockwise on the left (closer), clockwise on the right (far).
        let ar = r - band - 10 * px
        arrow(&ctx, c, ar, from: -100, to: -150, px: px)
        arrow(&ctx, c, ar, from: -80, to: -30, px: px)
    }

    /// A curved arrow on a circle of radius [ar], from angle [a0] to [a1] (degrees, 0 = right,
    /// clockwise), head at [a1].
    private static func arrow(_ ctx: inout GraphicsContext, _ c: CGPoint, _ ar: CGFloat, from a0: Double, to a1: Double, px: CGFloat) {
        func at(_ deg: Double) -> CGPoint {
            let t = deg * .pi / 180
            return CGPoint(x: c.x + ar * CGFloat(cos(t)), y: c.y + ar * CGFloat(sin(t)))
        }
        var p = Path()
        p.move(to: at(a0))
        for k in 1...16 { p.addLine(to: at(a0 + (a1 - a0) * Double(k) / 16)) }
        let t = a1 * .pi / 180
        let tip = at(a1)
        // Direction of travel at the tip (tangent), and the way out from the centre.
        let dir: CGFloat = a1 > a0 ? 1 : -1
        let tx = -CGFloat(sin(t)) * dir, ty = CGFloat(cos(t)) * dir
        let nx = CGFloat(cos(t)), ny = CGFloat(sin(t))
        let l: CGFloat = 8 * px
        p.move(to: CGPoint(x: tip.x - tx * l + nx * l * 0.6, y: tip.y - ty * l + ny * l * 0.6))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - tx * l - nx * l * 0.6, y: tip.y - ty * l - ny * l * 0.6))
        ctx.stroke(p, with: .color(Color.brass), style: StrokeStyle(lineWidth: 2 * px, lineCap: .round, lineJoin: .round))
    }
}

import SwiftUI

// The Android app's icons. Android has no icon font, no Material icons, no vector drawables: every
// icon is drawn with Canvas lines and arcs. These are the same drawings, same proportions (all in
// fractions of the icon box), same stroke widths and caps, so they look the same at any scale.
//
//     CineIcon(.gear)                       // 22dp box, Ivory, camera scale from the environment
//     CineIcon(.cross, size: 26)            // box width in Android dp
//     CineIcon(.star(filled: true), size: 14, color: .starAmber)
//
// Kind               Box (dp)   Kotlin source (app/src/main/java/ca/channel13/cineme/ui/)
// .gear              22         CameraScreen.kt:1752  GearIcon
// .lock(closed:)     18         CameraScreen.kt:825   LockIcon
// .storage           11x14      CameraScreen.kt:951   StorageIcon (SD card)
// .battery(level:)   20x11      CameraScreen.kt:972   BatteryIcon (Red fill below 15%)
// .refresh           22         CameraScreen.kt:1015  RefreshIcon (reconnect the gimbal)
// .moves             18         CameraScreen.kt:1424  MovesIcon (saved gimbal moves)
// .vibrate           24         CameraScreen.kt:1442  VibrateIcon
// .trash             18x20      CameraScreen.kt:1458  TrashIcon (also the library / player bin)
// .mic               16x22      CameraScreen.kt:1479  MicIcon (voice note)
// .uploading         16         CameraScreen.kt:1591  UploadingIcon (animated, 1100 ms loop, alpha 0.55)
// .center            22         CameraScreen.kt:1717  CenterIcon (focus back to the centre)
// .cross             26 (param) CameraScreen.kt:1731  CrossIcon (X: dialogs 26, Help / player 20,
//                                                     library 18, player Clear 16, focus ring 13)
// .play              18         CameraScreen.kt:1400  play triangle in the play / library key
// .drumIndex         8x14       CameraScreen.kt:1267  red index triangle on the drum (points left)
// .focusPoint        26         CameraScreen.kt:648   focus area "centre point": dot + ring
// .focusBrackets     72         CameraScreen.kt:663   tap-to-focus corner brackets (arm 22%, 2dp)
// .ringToggle        16         FocusRing.kt:165      circling arrow in the 30dp ring toggle key
// .sort              22         Library.kt:375        SortIcon (up and down arrows)
// .undo              22         Library.kt:390        UndoIcon
// .compare           26x18      Library.kt:403        CompareIcon (two tiles)
// .single            24x18      Library.kt:595        SingleIcon (one tile)
// .expand            18 (param) Library.kt:604        ExpandIcon (four corners; 14 on small tiles)
// .star(filled:)     22 (param) Library.kt:618        StarIcon (tiles 20 / 16 / 14)
// .pin               24         Library.kt:639        PinIcon (map)
// .grid              22         Library.kt:657        GridIcon (back to the grid)
// .bracket(isIn:)    34         PlayerActivity.kt:571 BracketIcon (In / Out keys)
// .speaker(muted:)   24         PlayerActivity.kt:644 SpeakerIcon (sound on / off; camera beeps)
// .chevron(left:)    20         PlayerActivity.kt:669 ChevronIcon (older / newer)
// .stopwatch         20         Timelapse.kt:171      StopwatchIcon (time-lapse key)
// .bin               20         RollDialog.kt:536     small bin on the saved moves list (#B9A98C, 1.6dp)
// .dialPlay/.dialStop 26        RollDialog.kt:346     play / stop disc in the corner of the dial glass
// CineGimbalBadge    22         CameraScreen.kt:1002  GimbalBadge: "G" on Live green / Red
//
// Not icons, drawn by their screens: the drum knurl (CameraScreen.kt:1237), focus ring (FocusRing.kt:113),
// level water (LevelPill.kt:96), framing guides, histogram, remote drawing, radio knobs and dials.

enum CineIconKind: Hashable {
    case gear, lock(closed: Bool), storage, battery(level: Int), refresh, moves, vibrate, trash, mic
    case uploading, center, cross, play, drumIndex, focusPoint, focusBrackets, ringToggle
    case sort, undo, compare, single, expand, star(filled: Bool), pin, grid
    case bracket(isIn: Bool), speaker(muted: Bool), chevron(left: Bool), stopwatch, bin, dialPlay, dialStop

    /// The Android Canvas size, in dp.
    var box: CGSize {
        switch self {
        case .gear, .refresh, .center, .sort, .undo, .grid, .star: return CGSize(width: 22, height: 22)
        case .lock, .moves, .play, .expand: return CGSize(width: 18, height: 18)
        case .storage: return CGSize(width: 11, height: 14)
        case .battery: return CGSize(width: 20, height: 11)
        case .vibrate, .pin, .speaker: return CGSize(width: 24, height: 24)
        case .trash: return CGSize(width: 18, height: 20)
        case .mic: return CGSize(width: 16, height: 22)
        case .uploading, .ringToggle: return CGSize(width: 16, height: 16)
        case .cross, .focusPoint, .dialPlay, .dialStop: return CGSize(width: 26, height: 26)
        case .drumIndex: return CGSize(width: 8, height: 14)
        case .focusBrackets: return CGSize(width: 72, height: 72)
        case .compare: return CGSize(width: 26, height: 18)
        case .single: return CGSize(width: 24, height: 18)
        case .bracket: return CGSize(width: 34, height: 34)
        case .chevron, .stopwatch, .bin: return CGSize(width: 20, height: 20)
        }
    }

    /// The colour Android draws it in when nothing else is said.
    var defaultColor: Color {
        switch self {
        case .drumIndex: return Color.rec
        case .bin: return Color.walnutHint
        case .dialPlay, .dialStop: return Color.dialInk.opacity(0.8)
        default: return Color.ivory
        }
    }

    /// Every kind once (the font / theme check screen).
    static let specimen: [CineIconKind] = [
        .gear, .lock(closed: false), .lock(closed: true), .storage, .battery(level: 80), .battery(level: 10), .refresh,
        .moves, .vibrate, .trash, .mic, .uploading, .center, .cross, .play, .drumIndex, .focusPoint, .ringToggle,
        .sort, .undo, .compare, .single, .expand, .star(filled: false), .star(filled: true), .pin, .grid,
        .bracket(isIn: true), .bracket(isIn: false), .speaker(muted: false), .speaker(muted: true),
        .chevron(left: true), .chevron(left: false), .stopwatch, .bin, .dialPlay, .dialStop,
    ]
}

/// An Android icon. `size` = the box width in Android dp (height follows the box's aspect), scaled by
/// the area's `cineScale`; nil = the Android default box. The layout size is exactly the box; strokes
/// that reach past it (the lifted lock shackle, round caps on the edge) draw outside, as Compose does.
struct CineIcon: View {
    @Environment(\.cineScale) private var s
    let kind: CineIconKind
    var size: CGFloat? = nil
    var color: Color? = nil

    init(_ kind: CineIconKind, size: CGFloat? = nil, color: Color? = nil) {
        self.kind = kind
        self.size = size
        self.color = color
    }

    var body: some View {
        let box = kind.box
        let w = s(size ?? box.width)
        let h = w * box.height / box.width
        let c = color ?? kind.defaultColor
        if kind == .uploading {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                IconCanvas(kind: kind, w: w, h: h, color: c, t: t).opacity(0.55)
            }
        } else {
            IconCanvas(kind: kind, w: w, h: h, color: c, t: 0)
        }
    }
}

/// Android `GimbalBadge` (CameraScreen.kt:1002-1010): 22dp circle, Live green when connected else Red,
/// "G" white 12sp w600. Android wraps it in a 6dp padded round touch area: add that around it.
struct CineGimbalBadge: View {
    @Environment(\.cineScale) private var s
    let connected: Bool
    var body: some View {
        Text("G")
            .font(s.font(12, .semibold))
            .foregroundStyle(Color.white)
            .frame(width: s(22), height: s(22))
            .background(Circle().fill(connected ? Color.live : Color.rec))
    }
}

/// The drawing: a canvas bigger than the box by a margin on every side (Compose doesn't clip icons),
/// laid out at the box size.
private struct IconCanvas: View {
    let kind: CineIconKind
    let w: CGFloat
    let h: CGFloat
    let color: Color
    let t: Double

    var body: some View {
        let m = max(w, h) * 0.3
        Canvas { ctx, _ in
            ctx.translateBy(x: m, y: m)
            IconPen(ctx: ctx, color: color).draw(kind, w, h, t)
        }
        .frame(width: w + 2 * m, height: h + 2 * m)
        .padding(-m)
        .allowsHitTesting(false)
    }
}

/// Compose DrawScope calls, SwiftUI side. Angles in degrees, clockwise from 3 o'clock (y down), as
/// Compose's drawArc; arcs on ovals are parametric, as Skia's.
private struct IconPen {
    let ctx: GraphicsContext
    let color: Color

    func line(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat, round: Bool = false, _ c: Color? = nil) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        ctx.stroke(p, with: .color(c ?? color), style: StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt))
    }

    func arc(_ r: CGRect, _ start: CGFloat, _ sweep: CGFloat, _ width: CGFloat, round: Bool = false) {
        var p = Path()
        let n = max(12, Int(abs(sweep) / 3))
        for i in 0...n {
            let a = (start + sweep * CGFloat(i) / CGFloat(n)) * .pi / 180
            let pt = CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt, lineJoin: .round))
    }

    func strokeRoundRect(_ r: CGRect, _ radius: CGFloat, _ width: CGFloat) {
        ctx.stroke(Path(roundedRect: r, cornerRadius: radius, style: .circular), with: .color(color), lineWidth: width)
    }

    func fillRoundRect(_ r: CGRect, _ radius: CGFloat, _ c: Color? = nil) {
        ctx.fill(Path(roundedRect: r, cornerRadius: radius, style: .circular), with: .color(c ?? color))
    }

    func strokeRect(_ r: CGRect, _ width: CGFloat) {
        ctx.stroke(Path(r), with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .miter))
    }

    func fillRect(_ r: CGRect, _ c: Color? = nil) { ctx.fill(Path(r), with: .color(c ?? color)) }

    func strokeCircle(_ c: CGPoint, _ r: CGFloat, _ width: CGFloat) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color), lineWidth: width)
    }

    func fillCircle(_ c: CGPoint, _ r: CGFloat, _ col: Color? = nil) {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(col ?? color))
    }

    func fillPolygon(_ pts: [CGPoint], _ c: Color? = nil) {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        ctx.fill(p, with: .color(c ?? color))
    }

    func strokePath(_ p: Path, _ width: CGFloat, round: Bool = false) {
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt))
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func draw(_ kind: CineIconKind, _ w: CGFloat, _ h: CGFloat, _ t: Double) {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func R(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect { CGRect(x: x, y: y, width: rw, height: rh) }

        switch kind {
        case .gear:
            let c = P(w / 2, h / 2)
            let r = w * 0.3
            for i in 0..<8 {
                let a = CGFloat(i) * 45 * .pi / 180
                line(P(c.x + r * cos(a), c.y + r * sin(a)), P(c.x + w * 0.47 * cos(a), c.y + w * 0.47 * sin(a)), w * 0.14)
            }
            strokeCircle(c, r, w * 0.12)

        case .lock(let closed):
            let lift = closed ? 0 : -h * 0.18
            arc(R(w * 0.22, lift + h * 0.02, w * 0.56, h * 0.6), 180, 180, w * 0.13)
            if closed {
                line(P(w * 0.22 + w * 0.065, h * 0.32), P(w * 0.22 + w * 0.065, h * 0.45), w * 0.13)
                line(P(w * 0.78 - w * 0.065, h * 0.32), P(w * 0.78 - w * 0.065, h * 0.45), w * 0.13)
            }
            fillRoundRect(R(w * 0.1, h * 0.42, w * 0.8, h * 0.56), w * 0.1)

        case .storage:
            let s = w * 0.14
            var p = Path()
            p.addLines([P(s / 2, s / 2), P(w * 0.62, s / 2), P(w - s / 2, h * 0.3), P(w - s / 2, h - s / 2), P(s / 2, h - s / 2)])
            p.closeSubpath()
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: s, lineJoin: .miter))
            for i in 0...2 {
                let x = w * (0.28 + CGFloat(i) * 0.17)
                line(P(x, h * 0.18), P(x, h * 0.36), s * 0.8)
            }

        case .battery(let level):
            let s = h * 0.13
            let body = w * 0.9
            strokeRoundRect(R(s / 2, s / 2, body - s, h - s), h * 0.2, s)
            fillRoundRect(R(body, h * 0.32, w - body, h * 0.36), h * 0.1)
            let f = CGFloat(min(max(level, 0), 100)) / 100
            let pad = s * 2
            fillRect(R(pad, pad, (body - pad * 2) * f, h - pad * 2), (0..<15).contains(level) ? Color.rec : color)

        case .refresh:
            let st = w * 0.1
            let r = w * 0.36
            let c = P(w / 2, w / 2)
            arc(R(c.x - r, c.y - r, 2 * r, 2 * r), 300, 290, st)
            let a: CGFloat = 300 * .pi / 180
            let tip = P(c.x + r * cos(a), c.y + r * sin(a))
            fillPolygon([P(tip.x + w * 0.2, tip.y - w * 0.02), P(tip.x - w * 0.06, tip.y - w * 0.16), P(tip.x - w * 0.02, tip.y + w * 0.16)])

        case .moves:
            let st = w * 0.1
            arc(R(w * 0.1, h * 0.25, w * 0.8, h * 0.9), 200, 140, st, round: true)
            let l = P(w * 0.13, h * 0.55)
            let r = P(w * 0.87, h * 0.55)
            line(l, P(l.x, l.y - h * 0.26), st, round: true)
            line(l, P(l.x + w * 0.24, l.y - h * 0.06), st, round: true)
            line(r, P(r.x, r.y - h * 0.26), st, round: true)
            line(r, P(r.x - w * 0.24, r.y - h * 0.06), st, round: true)

        case .vibrate:
            let st = w * 0.08
            strokeRoundRect(R(w * 0.34, h * 0.14, w * 0.32, h * 0.72), w * 0.06, st)
            for (x0, x1) in [(CGFloat(0.22), CGFloat(0.12)), (CGFloat(0.78), CGFloat(0.88))] {
                line(P(w * x0, h * 0.34), P(w * x1, h * 0.42), st, round: true)
                line(P(w * x1, h * 0.42), P(w * x0, h * 0.5), st, round: true)
                line(P(w * x0, h * 0.5), P(w * x1, h * 0.58), st, round: true)
            }

        case .trash:
            let s = w * 0.11
            line(P(0, h * 0.18), P(w, h * 0.18), s)
            strokeRect(R(w * 0.36, 0, w * 0.28, h * 0.12), s * 0.8)
            var p = Path()
            p.addLines([P(w * 0.1, h * 0.28), P(w * 0.9, h * 0.28), P(w * 0.8, h - s / 2), P(w * 0.2, h - s / 2)])
            p.closeSubpath()
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: s, lineJoin: .miter))
            for x in [CGFloat(0.38), CGFloat(0.62)] { line(P(w * x, h * 0.42), P(w * x, h * 0.84), s * 0.8) }

        case .mic:
            let s = w * 0.12
            fillRoundRect(R(w * 0.28, 0, w * 0.44, h * 0.6), w * 0.22)
            arc(R(w * 0.06, h * 0.2, w * 0.88, h * 0.56), 0, 180, s)
            line(P(w / 2, h * 0.76), P(w / 2, h * 0.94), s)
            line(P(w * 0.25, h * 0.95), P(w * 0.75, h * 0.95), s)

        case .uploading:
            let s = w * 0.1
            line(P(w * 0.15, h - s / 2), P(w * 0.85, h - s / 2), s, round: true, Color.dim)
            let y = h * (0.75 - CGFloat(t) * 0.65)
            let c = color.opacity((1 - t) * 0.8 + 0.2)
            line(P(w / 2, y), P(w / 2, y + h * 0.4), s, round: true, c)
            line(P(w / 2, y), P(w * 0.28, y + h * 0.22), s, round: true, c)
            line(P(w / 2, y), P(w * 0.72, y + h * 0.22), s, round: true, c)

        case .center:
            let c = w / 2
            let s = w * 0.09
            strokeCircle(P(c, c), c * 0.55, s)
            fillCircle(P(c, c), s * 1.1)
            for (dx, dy) in [(CGFloat(1), CGFloat(0)), (-1, 0), (0, 1), (0, -1)] {
                line(P(c + dx * c * 0.75, c + dy * c * 0.75), P(c + dx * c, c + dy * c), s)
            }

        case .cross:
            let s = w * 0.1
            line(P(s, s), P(w - s, w - s), s)
            line(P(w - s, s), P(s, w - s), s)

        case .play:
            fillPolygon([P(w * 0.2, 0), P(w, h / 2), P(w * 0.2, h)])

        case .drumIndex:
            fillPolygon([P(w, 0), P(0, h / 2), P(w, h)])

        case .focusPoint:
            fillCircle(P(w / 2, h / 2), w * 0.12)
            strokeCircle(P(w / 2, h / 2), w * 0.45, w * 1.5 / 26)

        case .focusBrackets:
            let l = w * 0.22
            let sw = w * 2 / 72
            for (x, y, dx, dy) in [(CGFloat(0), CGFloat(0), CGFloat(1), CGFloat(1)), (w, 0, -1, 1), (0, w, 1, -1), (w, w, -1, -1)] {
                line(P(x, y), P(x + dx * l, y), sw)
                line(P(x, y), P(x, y + dy * l), sw)
            }

        case .ringToggle:
            let c = P(w / 2, h / 2)
            let ar = w * (0.5 - 1.0 / 16)
            let lw = w * 1.6 / 16
            arc(R(c.x - ar, c.y - ar, ar * 2, ar * 2), -60, 290, lw, round: true)
            let a: CGFloat = (-60 + 290) * .pi / 180
            let tip = P(c.x + ar * cos(a), c.y + ar * sin(a))
            let tx = -sin(a), ty = cos(a), nx = cos(a), ny = sin(a)
            let l = w * 4.5 / 16
            line(tip, P(tip.x - tx * l + nx * l * 0.7, tip.y - ty * l + ny * l * 0.7), lw, round: true)
            line(tip, P(tip.x - tx * l - nx * l * 0.7, tip.y - ty * l - ny * l * 0.7), lw, round: true)

        case .sort:
            let st = w * 0.09
            line(P(w * 0.32, w * 0.15), P(w * 0.32, w * 0.85), st, round: true)
            line(P(w * 0.32, w * 0.15), P(w * 0.15, w * 0.34), st, round: true)
            line(P(w * 0.32, w * 0.15), P(w * 0.49, w * 0.34), st, round: true)
            line(P(w * 0.68, w * 0.15), P(w * 0.68, w * 0.85), st, round: true)
            line(P(w * 0.68, w * 0.85), P(w * 0.51, w * 0.66), st, round: true)
            line(P(w * 0.68, w * 0.85), P(w * 0.85, w * 0.66), st, round: true)

        case .undo:
            let st = w * 0.09
            arc(R(w * 0.2, w * 0.18, w * 0.64, w * 0.64), 200, 230, st, round: true)
            let tip = P(w * 0.22, w * 0.38)
            line(tip, P(tip.x + w * 0.02, tip.y - w * 0.26), st, round: true)
            line(tip, P(tip.x + w * 0.25, tip.y - w * 0.05), st, round: true)

        case .compare:
            let st = h * 0.1
            strokeRoundRect(R(st, st, w * 0.46 - st, h - st * 2), h * 0.12, st)
            strokeRoundRect(R(w * 0.54, st, w * 0.46 - st, h - st * 2), h * 0.12, st)

        case .single:
            let i = w * 0.02   // Android: 1 px
            strokeRoundRect(R(i, i, w - 2 * i, h - 2 * i), h * 0.15, h * 0.11)

        case .expand:
            let st = w * 0.12
            let l = w * 0.32
            for (x, y, dx, dy) in [(CGFloat(0), CGFloat(0), CGFloat(1), CGFloat(1)), (w, 0, -1, 1), (0, w, 1, -1), (w, w, -1, -1)] {
                line(P(x, y), P(x + dx * l, y), st, round: true)
                line(P(x, y), P(x, y + dy * l), st, round: true)
            }

        case .star(let filled):
            let cx = w / 2
            let cy = h / 2 + h * 0.04
            let r1 = w * 0.5
            let r2 = r1 * 0.45
            var p = Path()
            for i in 0..<10 {
                let r = i % 2 == 0 ? r1 : r2
                let a = (-90 + CGFloat(i) * 36) * .pi / 180
                let pt = P(cx + r * cos(a), cy + r * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            if filled { ctx.fill(p, with: .color(color)) } else {
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w * 0.08, lineJoin: .miter))
            }

        case .pin:
            var p = Path()
            p.move(to: P(w * 0.5, h * 0.95))
            p.addCurve(to: P(w * 0.18, h * 0.32), control1: P(w * 0.15, h * 0.55), control2: P(w * 0.15, h * 0.38))
            p.addCurve(to: P(w * 0.82, h * 0.32), control1: P(w * 0.25, h * 0.05), control2: P(w * 0.75, h * 0.05))
            p.addCurve(to: P(w * 0.5, h * 0.95), control1: P(w * 0.85, h * 0.38), control2: P(w * 0.85, h * 0.55))
            p.closeSubpath()
            strokePath(p, w * 0.08)
            fillCircle(P(w * 0.5, h * 0.36), w * 0.11)

        case .grid:
            let s = w * 0.42
            let g = w * 0.16
            for x in 0...1 {
                for y in 0...1 {
                    strokeRoundRect(R(CGFloat(x) * (s + g), CGFloat(y) * (s + g), s, s), s * 0.2, w * 0.08)
                }
            }

        case .bracket(let isIn):
            let st = w * 0.09
            let bx = isIn ? w * 0.22 : w * 0.78
            let lip = isIn ? w * 0.16 : -w * 0.16
            line(P(bx, h * 0.15), P(bx, h * 0.85), st, round: true)
            line(P(bx, h * 0.15), P(bx + lip, h * 0.15), st, round: true)
            line(P(bx, h * 0.85), P(bx + lip, h * 0.85), st, round: true)
            let tx = w * 0.5
            fillPolygon(isIn ? [P(tx, h * 0.3), P(tx + w * 0.3, h * 0.5), P(tx, h * 0.7)]
                             : [P(tx, h * 0.3), P(tx - w * 0.3, h * 0.5), P(tx, h * 0.7)])

        case .speaker(let muted):
            let s = w * 0.08
            fillPolygon([P(w * 0.08, h * 0.36), P(w * 0.28, h * 0.36), P(w * 0.52, h * 0.14),
                         P(w * 0.52, h * 0.86), P(w * 0.28, h * 0.64), P(w * 0.08, h * 0.64)])
            if muted {
                line(P(w * 0.66, h * 0.36), P(w * 0.94, h * 0.64), s, round: true)
                line(P(w * 0.94, h * 0.36), P(w * 0.66, h * 0.64), s, round: true)
            } else {
                arc(R(w * 0.42, h * 0.3, w * 0.36, h * 0.4), -45, 90, s, round: true)
                arc(R(w * 0.34, h * 0.14, w * 0.6, h * 0.72), -45, 90, s, round: true)
            }

        case .chevron(let left):
            let (a, b): (CGFloat, CGFloat) = left ? (0.65, 0.3) : (0.35, 0.7)
            var p = Path()
            p.addLines([P(w * a, h * 0.15), P(w * b, h * 0.5), P(w * a, h * 0.85)])
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w * 0.1, lineCap: .round, lineJoin: .miter))

        case .stopwatch:
            let st = w * 0.09
            let c = P(w / 2, w * 0.56)
            let r = w * 0.4
            strokeCircle(c, r, st)
            line(P(w * 0.42, w * 0.06), P(w * 0.58, w * 0.06), st, round: true)
            line(P(w / 2, w * 0.06), P(w / 2, c.y - r), st)
            line(c, P(c.x, c.y - r * 0.62), st, round: true)
            line(c, P(c.x + r * 0.45, c.y + r * 0.2), st, round: true)

        case .bin:
            let lw = w * 1.6 / 20
            line(P(w * 0.1, h * 0.22), P(w * 0.9, h * 0.22), lw)
            line(P(w * 0.38, h * 0.1), P(w * 0.62, h * 0.1), lw)
            strokeRect(R(w * 0.22, h * 0.3, w * 0.56, h * 0.62), lw)

        case .dialPlay, .dialStop:
            let r = w / 2
            fillCircle(P(r, r), r)
            if kind == .dialStop {
                fillRect(R(r * 0.62, r * 0.62, r * 0.76, r * 0.76), Color.dialGlass)
            } else {
                fillPolygon([P(r * 0.75, r * 0.55), P(r * 1.5, r), P(r * 0.75, r * 1.45)], Color.dialGlass)
            }
        }
    }
}

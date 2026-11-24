import Foundation
import SwiftUI

// Gimbal moves by the phone's own reading (the Android app's AutoLevel.kt and RollDialog.kt):
//  - roll, by the level's horizon angle; tilt (camera up/down), by gravity; pan, by how far the
//    phone turned since the move was set (pan only obeys the phone in lock mode);
//  - level tap: roll slowly until the horizon is level; ANGLE: to a set angle; MOVE: start -> end
//    in its seconds, back, round again while recording, then back to the start for the next take.
// Which way + turns each axis isn't known for sure, so if the first 1.5 s go the wrong way the
// direction flips and is saved.

enum MoveAxis: String, CaseIterable, Codable, Identifiable {
    case roll, tilt, pan
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// As Android's MoveAxis.label on the radio dialogs: ROLL, TILT, PAN.
    var tag: String { rawValue.uppercased() }
    /// Knob range, degrees.
    var max: Float { self == .roll ? 30 : self == .tilt ? 45 : 90 }
}

struct AxisMove: Codable, Equatable {
    var start: Float
    var end: Float
    var secs: Int
}

/// A saved move: axis, start and end angle, seconds one way.
struct MovePreset: Codable, Hashable, Identifiable {
    var axis: MoveAxis
    var start: Float
    var end: Float
    var secs: Int
    var id: String { "\(axis.rawValue)|\(start)|\(end)|\(secs)" }
    var label: String { "\(axis.tag) \(degText(start)) → \(degText(end)) in \(secs) s" }
}

/// What the moves remember (kept between launches).
struct MoveStore: Codable, Equatable {
    var axis: MoveAxis = .roll
    /// A move is set: recording runs it (the record button turns blue).
    var moveOn = false
    var roll = AxisMove(start: -5, end: 5, secs: 10)
    var tilt = AxisMove(start: -10, end: 10, secs: 10)
    var pan = AxisMove(start: -30, end: 30, secs: 10)
    var rollAngle: Float = 0
    var tiltAngle: Float = 0
    var rollSign: Float = 1
    var tiltSign: Float = 1
    var panSign: Float = 1
    var presets: [MovePreset] = []

    func move(_ a: MoveAxis) -> AxisMove { a == .roll ? roll : a == .tilt ? tilt : pan }
    mutating func setMove(_ a: MoveAxis, _ m: AxisMove) {
        switch a { case .roll: roll = m; case .tilt: tilt = m; case .pan: pan = m }
    }
    func sign(_ a: MoveAxis) -> Float { a == .roll ? rollSign : a == .tilt ? tiltSign : panSign }
}

// The record button's blue while a move is set: `Color.moveBlue` (Theme.swift, Android's Blue #3D7FE0).

func degText(_ v: Float) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.1f°", abs(v)) }

/// The engine. Main thread.
final class Mover: ObservableObject {
    @Published var store: MoveStore = Mover.load() { didSet { if store != oldValue { save() } } }
    @Published private(set) var running = false

    weak var camera: Camera?
    weak var gimbal: Gimbal?
    weak var level: Level?
    /// Tracking running: moves wait (set by the rig).
    var trackingBusy: () -> Bool = { false }

    private static let doneDeg: Float = 0.4
    /// Below about 0.07 the roll motor doesn't move at all (measured: 0.1 = 5°/s, 0.2 = 10°/s).
    private static let minSpeed: Float = 0.09
    private static let timeout: TimeInterval = 12
    /// Move: how fast the joystick speed may change per tick (no jolts, also at the turns).
    private static let sweepSlew: Float = 0.03

    private var axis: MoveAxis = .roll
    private var gen = 0
    private var startedAt = Date()
    private var startErr: Float = .nan
    private var startReading: Float = 0
    private var firstDir: Float = 0
    private var flipped = false
    private var steady = 0
    private var target: Float = 0
    private var sweeping = false
    private var doneMsg: String? = nil
    private var pulse = 0
    private var sweepV: Float = 0
    private var leg: Float = 1
    private var braking = false
    private var history: [(TimeInterval, Float)] = []
    private var slow = false
    private var lastEnd: Float = 0
    /// What to do when the current move arrives (the level's check).
    private var then: (() -> Void)? = nil
    /// Time-lapse with a move: keeps the gimbal's mode until [timelapseEnd].
    private var hold = false
    private var tlAxis: MoveAxis = .roll

    private static func load() -> MoveStore {
        guard let d = UserDefaults.standard.data(forKey: "moves"), let s = try? JSONDecoder().decode(MoveStore.self, from: d) else { return MoveStore() }
        return s
    }
    private func save() { if let d = try? JSONEncoder().encode(store) { UserDefaults.standard.set(d, forKey: "moves") } }

    private func msg(_ m: String) { camera?.message = m }

    /// Screenshot runs: a couple of saved moves to show.
    func fakeForShots() {
        if store.presets.isEmpty {
            store.presets = [MovePreset(axis: .roll, start: -5, end: 5, secs: 10), MovePreset(axis: .pan, start: -30, end: 30, secs: 20)]
        }
    }
    private var tiltReading: Float { level?.tilt.map { Float($0) } ?? .nan }

    // MARK: - what the screen asks for

    /// Tap on the level pill: the horizon only, slowly until level. Tap again to stop.
    func toggleLevel() {
        if running { then = nil; finish(nil); return }
        slow = true
        then = { [weak self] in self?.check(1) }
        moveTo(0, nil, .roll)
    }

    /// After the horizon move the gimbal goes back to its own mode, and that shifts the horizon a
    /// little. Look again a moment later; if it's off, roll to the other side by that shift. Twice at most.
    private func check(_ round: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let r = self.tiltReading
            if r.isNaN || abs(r) <= Mover.doneDeg || round > 2 {
                self.slow = false
                self.msg(r.isNaN || abs(r) <= 1 ? "Level" : String(format: "Level (horizon %.1f°)", r))
                return
            }
            let shift = r - self.lastEnd
            self.then = { [weak self] in self?.check(round + 1) }
            self.moveTo(-shift, nil, .roll)
        }
    }

    /// ANGLE: roll or tilt to [angle] degrees.
    func goTo(_ angle: Float, _ a: MoveAxis, done: String? = "Angle set") {
        slow = false
        then = nil
        moveTo(angle, done, a)
    }

    /// The move was set (SET or USE): to its start. Pan counts from where the camera looks now.
    func armMove(_ a: MoveAxis, start: Float, done: String?) {
        if a == .pan { level?.zeroHeading() }
        goTo(start, a, done: done)
    }

    /// Recording started with a move set.
    func startSweep() {
        guard store.moveOn else { return }
        then = nil
        axis = store.axis
        guard canRun() else { return }
        sweeping = true
        doneMsg = nil
        begin()
    }

    /// Recording stopped: back to the start angle, ready for the next take.
    func stopSweep() {
        guard sweeping else { return }
        sweeping = false
        finish(nil)
        let a = store.axis, s = store.move(a).start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.goTo(s, a, done: nil) }
    }

    func stop() { sweeping = false; then = nil; finish(nil) }

    // MARK: - time-lapse

    /// A time-lapse with a saved move begins: to its start, then [timelapseStep] after each photo.
    func timelapseBegin(_ a: MoveAxis, start: Float) {
        hold = true
        tlAxis = a
        armMove(a, start: start, done: nil)
    }

    /// After a photo: on to [angle] (a small step; skipped if the last one is still going).
    func timelapseStep(_ angle: Float) {
        guard hold, !running else { return }
        goTo(angle, tlAxis, done: nil)
    }

    func timelapseEnd() {
        guard hold else { return }
        hold = false
        then = nil
        finish(nil)
        gimbal?.releaseControl()
    }

    // MARK: - the loop

    private func moveTo(_ angle: Float, _ done: String?, _ a: MoveAxis) {
        axis = a
        guard canRun() else { return }
        if a == .roll && abs(tiltReading - angle) <= Mover.doneDeg {
            if let d = done { msg(d) }
            lastEnd = tiltReading
            let next = then
            then = nil
            next?()
            return
        }
        target = angle
        sweeping = false
        doneMsg = done
        begin()
    }

    private func canRun() -> Bool {
        var m: String? = nil
        if gimbal?.state != .connected { m = "Gimbal not connected" }
        else if trackingBusy() { m = "Stop tracking first" }
        else if axis == .roll && tiltReading.isNaN { m = "Hold the phone up to level it" }
        if let m = m { msg(m) }
        return m == nil
    }

    private func begin() {
        gen += 1
        running = true
        startedAt = Date()
        startErr = .nan
        flipped = false
        steady = 0
        sweepV = 0
        leg = 1
        braking = false
        history.removeAll()
        // Roll only obeys in mode 2; tilt in 0 and 1 (keep lock if it's in lock); pan only in lock.
        if let g = gimbal {
            g.takeControl(axis == .tilt ? g.modeForTilt : axis == .pan ? Zhiyun.modeLock : Zhiyun.modeRoll)
        }
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + (axis == .roll ? 0 : 0.2)) { self.tick(g) }
    }

    private func reading() -> Float {
        switch axis {
        case .roll: return tiltReading
        case .tilt: return level?.pitch.map { Float($0) } ?? .nan
        case .pan: return Float(level?.heading ?? .nan)
        }
    }

    /// Where the axis should be [t] seconds after the start. Sweep: start → end → start …, a triangle wave.
    private func goal(_ t: TimeInterval) -> Float {
        guard sweeping else { return target }
        let m = store.move(axis)
        let period = Double(max(1, m.secs))
        let k = Float(t.truncatingRemainder(dividingBy: 2 * period) / period)
        let f = k <= 1 ? k : 2 - k
        return m.start + (m.end - m.start) * f
    }

    private func tick(_ g: Int) {
        guard g == gen, running else { return }
        let t = reading()
        let el = Date().timeIntervalSince(startedAt)
        func again() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.tick(g) } }
        if gimbal?.state != .connected { finish("Gimbal move stopped"); return }
        if t.isNaN {
            if axis != .roll && el < 1 { again(); return }
            finish("Gimbal move stopped"); return
        }
        let err = goal(el) - t
        if startErr.isNaN { startErr = abs(err); startReading = t; firstDir = err > 0 ? 1 : err < 0 ? -1 : 0 }
        if sweeping { sweepTick(el, t); again(); return }
        if abs(err) <= Mover.doneDeg {
            // A few readings in a row, so a shake doesn't end it early.
            steady += 1
            if steady >= 3 {
                lastEnd = t
                let next = then
                then = nil
                finish(doneMsg)
                next?()
                return
            }
            send(0)
        } else {
            steady = 0
            // Direction check, once, 1.5 s in: moved the other way (or not at all) = + turns the
            // other way on this gimbal: flip and remember.
            let moved = (t - startReading) * firstDir
            if !flipped && el > 1.5 {
                flipped = true
                if firstDir != 0 && startErr > 1.5 && moved < 0.5 { flipSign() }
            }
            if el > Mover.timeout { finish("Couldn't get there, check the gimbal"); return }
            // Proportional, slower near the goal; close to it short nudges (one tick on, two off).
            pulse += 1
            let mag: Float
            if abs(err) < 0.15 { mag = 0 }
            else if abs(err) < 2 { mag = pulse % 3 == 0 ? Mover.minSpeed : 0 }
            else { mag = min(max(abs(err) * 0.03, Mover.minSpeed), slow ? 0.12 : 0.5) }
            let v = min(max(mag * (err > 0 ? 1 : -1), -0.6), 0.6)
            send(axisSpeed(v))
        }
        again()
    }

    /// One step of the move: a steady speed worked out from the angles and seconds; the reading only
    /// decides when to slow down for the turn. Joystick at full: about 65°/s at joystick speed 4 (200),
    /// in proportion to the setting (measured on Android).
    private func sweepTick(_ el: TimeInterval, _ t: Float) {
        let js = gimbal?.joystickSpeed ?? 3
        let degPerUnit: Float = 0.325 * Float([50, 100, 150, 200, 260][max(1, min(5, js)) - 1])
        let m = store.move(axis)
        let a = m.start, b = m.end
        let dirAB: Float = b > a ? 1 : b < a ? -1 : 0
        if !flipped && el > 1.5 {
            flipped = true
            if (t - startReading) * dirAB < -1 { flipSign() }
        }
        history.append((el, t))
        if history.count > 11 { history.removeFirst() }
        let tgt = leg > 0 ? b : a
        let from = leg > 0 ? a : b
        let dir: Float = tgt > from ? 1 : tgt < from ? -1 : 0
        let cruise = min(max(abs(b - a) / Float(max(1, m.secs)) / degPerUnit, 0.01), 0.6)
        let rate: Float
        if history.count >= 6, let f = history.first, let l = history.last {
            rate = abs(l.1 - f.1) / Float(max(0.001, l.0 - f.0))
        } else {
            rate = abs(sweepV) * degPerUnit
        }
        let slew = max(Mover.sweepSlew, cruise / 3)
        // Slowing down takes |v| / slew ticks; on average half the speed. Plus the reading's lag.
        let stopDeg = rate * (abs(sweepV) / slew * 0.1 / 2 + 0.3)
        let left = (tgt - t) * dir
        if !braking && left <= stopDeg { braking = true }
        let want = braking ? 0 : cruise * dir
        sweepV += min(max(want - sweepV, -slew), slew)
        // Stopped at the end: turn round.
        if braking && sweepV == 0 { braking = false; leg = -leg; history.removeAll() }
        send(axisSpeed(sweepV))
    }

    /// Joystick value for [v] (+ = the reading goes up).
    private func axisSpeed(_ v: Float) -> Float { v * store.sign(axis) }

    private func send(_ speed: Float) {
        guard let g = gimbal else { return }
        switch axis {
        case .tilt: g.move(pan: 0, tilt: speed)
        case .pan: g.move(pan: speed, tilt: nil)
        case .roll: g.roll(speed)
        }
    }

    private func flipSign() {
        switch axis {
        case .roll: store.rollSign = -store.rollSign
        case .tilt: store.tiltSign = -store.tiltSign
        case .pan: store.panSign = -store.panSign
        }
    }

    private func finish(_ message: String?) {
        guard running else { return }
        running = false
        gen += 1
        gimbal?.stopMove()
        // A time-lapse keeps the gimbal's mode between its small steps.
        if !hold { gimbal?.releaseControl() }
        if let m = message { msg(m) }
    }
}


// MARK: - the old-radio pieces (RollDialog.kt): panel, piano key, knob, dial glass

/// Compose px (dash lengths in RollDialog.kt are raw pixels on the 2.625 px/dp Pixel) -> iOS points.
func radioPx(_ v: CGFloat) -> CGFloat { v / 2.625 * Theme.device }

extension View {
    /// The walnut panel (RollDialog.kt:117-124): vertical gradient Walnut -> WalnutDark, 2dp Brass
    /// border, corner `radius` dp, padding in dp. Camera scale.
    func radioPanel(radius: CGFloat = 18, h: CGFloat = 26, v: CGFloat = 18) -> some View {
        let s = CineScale.cam
        let shape = cineRect(s(radius))
        return self
            .padding(.horizontal, s(h))
            .padding(.vertical, s(v))
            .background(shape.fill(LinearGradient(colors: [Color.walnut, Color.walnutDark], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(Color.brass, lineWidth: s(2)))
            .contentShape(shape)
    }
}

/// Cream piano key (RollDialog.kt:480-497): 96x44 (wide 130x44), corners top 3 / bottom 6. Up: light
/// gradient over a 4dp darker front edge. Down: darker, 2dp lower, a small red lamp top right.
struct PianoKey: View {
    let text: String
    var down = false
    var wide = false
    var enabled = true
    let action: () -> Void
    private let s = CineScale.cam

    init(_ text: String, down: Bool = false, wide: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.text = text
        self.down = down
        self.wide = wide
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        let w = s(wide ? 130 : 96), h = s(44)
        let shape = UnevenRoundedRectangle(topLeadingRadius: s(3), bottomLeadingRadius: s(6),
                                           bottomTrailingRadius: s(6), topTrailingRadius: s(3), style: .circular)
        Button(action: action) {
            Text(text)
                .font(s.font(15, .semibold))
                .tracking(s.tracking(0.15, sp: 15))
                .foregroundStyle(Color.dialInk)
                .lineLimit(1)
                .frame(width: w, height: h)
                .background(shape.fill(LinearGradient(colors: down ? [Color.keyDownTop, Color.keyDownBottom] : [Color.keyUpTop, Color.keyUpBottom],
                                                      startPoint: .top, endPoint: .bottom)))
                // 1dp border inside the edge: a 2dp stroke on the edge, its outer half clipped.
                .overlay(shape.stroke(Color.keyBorder, lineWidth: s(2)))
                .clipShape(shape)
                .overlay(alignment: .topTrailing) {
                    if down {
                        Circle().fill(Color.keyLamp).frame(width: s(7), height: s(7))
                            .padding(.top, s(7)).padding(.trailing, s(8))
                    }
                }
                .background(alignment: .top) {
                    if !down { shape.fill(Color.keyFront).frame(width: w, height: h).offset(y: s(4)) }
                }
                .contentShape(shape)
        }
        .buttonStyle(CinePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .offset(y: down ? s(2) : 0)
    }
}

/// Bakelite knob with a knurled rim and a pointer over a 270° scale (RollDialog.kt:419-476).
/// Turn it with a finger round its centre (270° of turning = the whole scale); near the centre a
/// straight drag works too (right / up = more, as on Android: three knob widths = the whole scale).
struct RadioKnob: View {
    let label: String
    let value: Float
    let lo: Float
    let hi: Float
    let step: Float
    var size: CGFloat = 96
    let format: (Float) -> String
    let onChange: (Float) -> Void
    private let s = CineScale.cam
    @State private var raw: Float = 0
    @State private var last: CGPoint? = nil

    init(_ label: String, value: Float, lo: Float, hi: Float, step: Float, size: CGFloat = 96,
         format: @escaping (Float) -> String, onChange: @escaping (Float) -> Void) {
        self.label = label
        self.value = value
        self.lo = lo
        self.hi = hi
        self.step = step
        self.size = size
        self.format = format
        self.onChange = onChange
    }

    var body: some View {
        let side = s(size)
        VStack(spacing: 0) {
            Canvas { ctx, sz in draw(ctx, sz) }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in turn(g.location, side: side) }
                        .onEnded { _ in last = nil }
                )
            Text(format(value)).font(s.font(16, .medium)).foregroundStyle(Color.amber)
            Text(label).font(s.font(11)).tracking(s.tracking(0.2, sp: 11)).foregroundStyle(Color.brass)
        }
    }

    private func turn(_ p: CGPoint, side: CGFloat) {
        guard let l = last else { last = p; raw = value; return }
        let c = CGPoint(x: side / 2, y: side / 2)
        let range = hi - lo
        var r = raw
        if hypot(l.x - c.x, l.y - c.y) > side * 0.18 && hypot(p.x - c.x, p.y - c.y) > side * 0.18 {
            // Round the centre: clockwise (y down) = more.
            var da = atan2(p.y - c.y, p.x - c.x) - atan2(l.y - c.y, l.x - c.x)
            if da > .pi { da -= 2 * .pi } else if da < -.pi { da += 2 * .pi }
            r += Float(da / (1.5 * .pi)) * range
        } else {
            r += Float(((p.x - l.x) - (p.y - l.y)) / (side * 3)) * range
        }
        r = Swift.min(Swift.max(r, lo), hi)
        raw = r
        last = p
        let stepped = (r / step).rounded() * step
        if stepped != value { onChange(stepped) }
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let r = sz.width / 2
        let k = CGFloat((value - lo) / Swift.max(hi - lo, 0.0001))
        func seg(_ deg: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ w: CGFloat, _ col: Color, round: Bool = false) {
            let a = deg * .pi / 180
            var p = Path()
            p.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
            p.addLine(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
            ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: round ? .round : .butt))
        }
        func disc(_ at: CGPoint, _ rad: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: at.x - rad, y: at.y - rad, width: rad * 2, height: rad * 2))
        }
        // Scale ticks, 270° from the bottom left to the bottom right; lit up to the value.
        for i in 0...20 {
            let lit = CGFloat(i) / 20 <= k + 0.001
            seg(135 + CGFloat(i) * 13.5, r * 0.86, r * 0.98, i % 5 == 0 ? s(2.5) : s(1.2), lit ? Color.amber : Color.knobTick)
        }
        let kr = r * 0.74
        // Shadow, then the body.
        ctx.fill(disc(CGPoint(x: c.x, y: c.y + s(3)), kr), with: .color(Color.knobShadow))
        ctx.fill(disc(c, kr), with: .radialGradient(Gradient(colors: [Color.knobBodyLight, Color.knobBodyDark]),
                                                    center: CGPoint(x: c.x - kr * 0.3, y: c.y - kr * 0.4),
                                                    startRadius: 0, endRadius: kr * 1.6))
        // Knurled rim, turning with the value.
        let turn = -135 + 270 * k
        for i in 0..<36 { seg(CGFloat(i) * 10 + turn, kr * 0.86, kr * 0.99, s(1.5), Color.knobKnurl) }
        // Cap with a soft highlight, and the cream pointer.
        ctx.fill(disc(c, kr * 0.72), with: .radialGradient(Gradient(colors: [Color.knobCapLight, Color.knobCapDark]),
                                                          center: CGPoint(x: c.x - kr * 0.2, y: c.y - kr * 0.3),
                                                          startRadius: 0, endRadius: kr))
        seg(turn - 90, kr * 0.2, kr * 0.66, s(3), Color.dialGlass, round: true)
    }
}

/// About how fast the gimbal gets to a single angle (for the ANGLE preview), degrees per second.
private let previewDegPerSec: Float = 12

/// The dial glass (RollDialog.kt:252-363): horizon fixed, the camera frame turned (roll), the camera
/// from the side (tilt) or from above (pan). Start solid, end dashed; tap the glass to play the move
/// at its real speed (back and forth once for MOVE, level to the angle for ANGLE). Tap again: stop.
struct DialWindow: View {
    let axis: MoveAxis
    let move: Bool
    let angle: Float
    let start: Float
    let end: Float
    let secs: Int
    var width: CGFloat = 230
    var height: CGFloat = 150
    var caption = true
    private let s = CineScale.cam
    @State private var playing = false
    @State private var t0 = Date()

    private struct Key: Equatable {
        let axis: MoveAxis, move: Bool, angle: Float, start: Float, end: Float, secs: Int
    }

    init(axis: MoveAxis, move: Bool, angle: Float, start: Float, end: Float, secs: Int,
         width: CGFloat = 230, height: CGFloat = 150, caption: Bool = true) {
        self.axis = axis
        self.move = move
        self.angle = angle
        self.start = start
        self.end = end
        self.secs = secs
        self.width = width
        self.height = height
        self.caption = caption
    }

    /// How long the preview runs, seconds.
    private var total: Double {
        if move { return 2 * Double(max(1, secs)) }
        return Double(max(abs(angle) / previewDegPerSec, 0.4)) + 0.6
    }

    private func value(_ t: Double) -> Float {
        if move {
            let period = Double(max(1, secs))
            let k = Float(min(t, 2 * period) / period)
            return start + (end - start) * (k <= 1 ? k : 2 - k)
        }
        let ms = max(abs(angle) / previewDegPerSec, 0.4)
        return angle * min(Float(t) / ms, 1)
    }

    var body: some View {
        let shape = cineRect(s(10))
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TimelineView(.animation(minimumInterval: nil, paused: !playing)) { tl in
                    let now: Float? = playing ? value(tl.date.timeIntervalSince(t0)) : nil
                    Canvas { ctx, size in draw(ctx, size, now) }
                }
                .frame(width: s(width), height: s(height))
                .background(Color.dialGlass)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.brass, lineWidth: s(3)))
                .contentShape(shape)
                .onTapGesture {
                    if !playing { t0 = Date() }
                    playing.toggle()
                }
                CineIcon(playing ? .dialStop : .dialPlay, size: caption ? 26 : 20)
                    .padding(s(caption ? 8 : 5))
                    .allowsHitTesting(false)
            }
            if caption {
                let name = axis == .tilt ? "Camera" : axis == .pan ? "Looking" : "Horizon"
                Text(move ? "\(degText(start))  →  \(degText(end))  in \(secs) s" : "\(name) \(degText(angle))")
                    .font(s.font(13))
                    .foregroundStyle(Color.amber)
                    .padding(.top, s(6))
            }
        }
        // Any change to the move stops the preview.
        .onChange(of: Key(axis: axis, move: move, angle: angle, start: start, end: end, secs: secs)) { _, _ in playing = false }
        .task(id: playing) {
            guard playing else { return }
            try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            if !Task.isCancelled { playing = false }
        }
    }

    // MARK: drawing

    private func line(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ w: CGFloat, _ c: Color, dash: [CGFloat] = []) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .butt, dash: dash))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ now: Float?) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let fw = size.width * 0.5
        let tick = Color.dialInk.opacity(0.6)
        if axis == .roll {
            // Scale marks along the top, like a tuning dial: every 5°, longer every 15°.
            for d in stride(from: -30, through: 30, by: 5) {
                let x = c.x + CGFloat(d) / 30 * size.width * 0.42
                line(ctx, CGPoint(x: x, y: s(8)), CGPoint(x: x, y: s(d % 15 == 0 ? 18 : 13)), s(1), tick)
            }
        }
        // The world: sky above a fixed horizon (pan: seen from above, no horizon).
        if axis != .pan {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: c.y)), with: .color(Color.dialSky))
            line(ctx, CGPoint(x: 0, y: c.y), CGPoint(x: size.width, y: c.y), s(1.5), Color.dialInk)
        }
        // Pan, from above: the camera at the bottom, looking up the glass, turned right by +.
        let panPivot = CGPoint(x: c.x, y: size.height * 0.86)
        if axis == .pan {
            let r = size.height * 0.7
            for d in stride(from: -90, through: 90, by: 15) {
                let a = CGFloat(d - 90) * .pi / 180
                let r0 = r - s(d % 45 == 0 ? 9 : 5)
                line(ctx, CGPoint(x: panPivot.x + r0 * cos(a), y: panPivot.y + r0 * sin(a)),
                     CGPoint(x: panPivot.x + r * cos(a), y: panPivot.y + r * sin(a)), s(1), tick)
            }
        }
        // Tilt, from the side: the camera on its axis, pointing right, with what it sees.
        let pivot = CGPoint(x: size.width * 0.26, y: c.y)
        if axis == .tilt {
            let r = size.height * 0.42
            for d in stride(from: -45, through: 45, by: 15) {
                let a = CGFloat(-d) * .pi / 180
                let r0 = r - s(d % 45 == 0 ? 9 : 5)
                line(ctx, CGPoint(x: pivot.x + r0 * cos(a), y: pivot.y + r0 * sin(a)),
                     CGPoint(x: pivot.x + r * cos(a), y: pivot.y + r * sin(a)), s(1), tick)
            }
        }
        // Compose's color.copy(alpha) replaces the alpha: keep the ink and its alpha apart.
        func at(_ deg: Float, _ alpha: Double, live: Bool, dashed: Bool) {
            let ink = live ? Color.liveMove : Color.dialInk
            switch axis {
            case .tilt: sideCamera(ctx, size, pivot, size.width * 0.12, deg, ink, alpha, dashed: dashed, filled: live)
            case .pan: sideCamera(ctx, size, panPivot, size.width * 0.1, 90 - deg, ink, alpha, dashed: dashed, filled: live)
            case .roll: frame(ctx, c, fw, deg, ink.opacity(alpha), dashed: dashed)
            }
        }
        if !move {
            if let n = now { at(0, 0.35, live: false, dashed: true); at(n, 1, live: true, dashed: false) }
            else { at(angle, 1, live: true, dashed: false) }
        } else {
            at(start, 0.55, live: false, dashed: false)
            at(end, 0.55, live: false, dashed: true)
            at(now ?? start, 1, live: true, dashed: false)
        }
    }

    /// The camera from the side (tilt) or above (pan), on its axis at `pivot`, pointing right and
    /// turned up by `deg`, with its angle of view (shaded when `filled`, the live one).
    private func sideCamera(_ ctx: GraphicsContext, _ size: CGSize, _ pivot: CGPoint, _ w: CGFloat, _ deg: Float,
                            _ ink: Color, _ alpha: Double, dashed: Bool, filled: Bool) {
        let h = w * 0.62
        let color = ink.opacity(alpha)
        let dash = dashed ? [radioPx(7), radioPx(5)] : []
        var g = ctx
        g.translateBy(x: pivot.x, y: pivot.y)
        g.rotate(by: .degrees(Double(-deg)))
        g.translateBy(x: -pivot.x, y: -pivot.y)
        // Where the shot looks: a soft wedge from the lens out of the window.
        let lens = CGPoint(x: pivot.x + w / 2 + w * 0.32, y: pivot.y)
        let far = size.width
        let spread: CGFloat = 0.38
        let top = CGPoint(x: lens.x + far, y: lens.y - far * spread)
        let bottom = CGPoint(x: lens.x + far, y: lens.y + far * spread)
        if filled {
            var p = Path()
            p.addLines([lens, top, bottom])
            p.closeSubpath()
            g.fill(p, with: .color(ink.opacity(0.14)))
        }
        line(g, lens, top, s(1), ink.opacity(0.5), dash: dash)
        line(g, lens, bottom, s(1), ink.opacity(0.5), dash: dash)
        // Body, lens and the little viewfinder bump on top.
        let style = StrokeStyle(lineWidth: s(2), dash: dash)
        g.stroke(Path(roundedRect: CGRect(x: pivot.x - w / 2, y: pivot.y - h / 2, width: w, height: h), cornerRadius: s(3), style: .circular),
                 with: .color(color), style: style)
        g.stroke(Path(CGRect(x: pivot.x + w / 2, y: pivot.y - h * 0.28, width: w * 0.32, height: h * 0.56)), with: .color(color), style: style)
        g.stroke(Path(CGRect(x: pivot.x - w * 0.3, y: pivot.y - h / 2 - h * 0.22, width: w * 0.3, height: h * 0.22)), with: .color(color), style: style)
        // The axis.
        let r = s(2.5)
        ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - r, y: pivot.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }

    /// The camera frame turned so the horizon looks `deg` on screen (+ = its right side higher).
    private func frame(_ ctx: GraphicsContext, _ c: CGPoint, _ w: CGFloat, _ deg: Float, _ color: Color, dashed: Bool) {
        let h = w * 9 / 16
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .degrees(Double(deg)))
        g.translateBy(x: -c.x, y: -c.y)
        g.stroke(Path(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)), with: .color(color),
                 style: StrokeStyle(lineWidth: s(2), dash: dashed ? [radioPx(8), radioPx(6)] : []))
        // A little "up" mark on the top edge.
        line(g, CGPoint(x: c.x, y: c.y - h / 2), CGPoint(x: c.x, y: c.y - h / 2 - s(6)), s(2), color)
    }
}

// MARK: - the moves dialog (RollDialog.kt)

/// The moves button / long press on the level. Three axes: ROLL (horizon), TILT (camera up / down) and
/// PAN (left / right; MOVE only, counted from where the camera looks when it's set). ANGLE: one knob,
/// OK moves the gimbal there. MOVE: start, end and time; SET keeps it: recording then goes
/// start -> end -> start ... until stop. Tap outside = CANCEL. Put it over the camera screen.
struct MovesDialog: View {
    @ObservedObject var mover: Mover
    let onClose: () -> Void
    private let s = CineScale.cam
    @State private var axis: MoveAxis
    @State private var move: Bool
    @State private var roll: AxisMove
    @State private var tilt: AxisMove
    @State private var pan: AxisMove
    @State private var rollAngle: Float
    @State private var tiltAngle: Float
    @State private var loading = false
    @State private var askDelete: MovePreset? = nil

    init(mover: Mover, onClose: @escaping () -> Void) {
        _mover = ObservedObject(wrappedValue: mover)
        self.onClose = onClose
        let st = mover.store
        _axis = State(initialValue: st.axis)
        _move = State(initialValue: st.moveOn || st.axis == .pan)
        _roll = State(initialValue: st.roll)
        _tilt = State(initialValue: st.tilt)
        _pan = State(initialValue: st.pan)
        _rollAngle = State(initialValue: st.rollAngle)
        _tiltAngle = State(initialValue: st.tiltAngle)
    }

    private var current: AxisMove { axis == .roll ? roll : axis == .tilt ? tilt : pan }
    private func setCurrent(_ m: AxisMove) {
        switch axis { case .roll: roll = m; case .tilt: tilt = m; case .pan: pan = m }
    }
    private var angle: Float { axis == .tilt ? tiltAngle : rollAngle }
    private var presets: [MovePreset] { mover.store.presets }

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            ZStack {
                CineScrim(color: .scrimDark, onTapOutside: onClose) {
                    Group {
                        if loading { savedMoves(portrait) } else { controls(portrait) }
                    }
                    .radioPanel()
                }
                if let p = askDelete { deletePopup(p) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The panel centred on the whole screen, as Android's (RollDialog.kt:116), not the safe area.
        .ignoresSafeArea()
        .cineScale(.cam)
        // Pan has no single angle (it counts from where the camera looks): MOVE only.
        .onChange(of: axis) { _, a in if a == .pan { move = true } }
    }

    // MARK: the knobs page

    @ViewBuilder private func controls(_ portrait: Bool) -> some View {
        VStack(spacing: 0) {
            if portrait {
                HStack(spacing: s(8)) { axisKeys }
                Spacer().frame(height: s(10))
                HStack(spacing: s(8)) { modeKeys }
            } else {
                HStack(spacing: 0) {
                    HStack(spacing: s(8)) { axisKeys }
                    Spacer().frame(width: s(30))
                    HStack(spacing: s(8)) { modeKeys }
                }
            }
            Spacer().frame(height: s(14))
            if portrait {
                dial(width: 300, height: 170)
                Spacer().frame(height: s(12))
                HStack(spacing: s(14)) { knobs(84) }
            } else {
                HStack(spacing: s(22)) {
                    dial(width: 230, height: 150)
                    knobs(96)
                }
            }
            Spacer().frame(height: s(16))
            if portrait {
                HStack(alignment: .top, spacing: s(12)) { setKey; saveKey }
                Spacer().frame(height: s(12))
                HStack(alignment: .top, spacing: s(12)) { loadKey; cancelKey }
            } else {
                HStack(alignment: .top, spacing: s(12)) { setKey; saveKey; loadKey; cancelKey }
            }
            Text(hint)
                .font(s.font(12))
                .foregroundStyle(Color.walnutHint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s(10))
        }
    }

    @ViewBuilder private var axisKeys: some View {
        PianoKey("ROLL", down: axis == .roll) { axis = .roll }
        PianoKey("TILT", down: axis == .tilt) { axis = .tilt }
        PianoKey("PAN", down: axis == .pan) { axis = .pan }
    }

    @ViewBuilder private var modeKeys: some View {
        PianoKey("ANGLE", down: !move, enabled: axis != .pan) { move = false }
        PianoKey("MOVE", down: move) { move = true }
    }

    private func dial(width: CGFloat, height: CGFloat) -> some View {
        DialWindow(axis: axis, move: move, angle: angle, start: current.start, end: current.end, secs: current.secs,
                   width: width, height: height)
    }

    @ViewBuilder private func knobs(_ size: CGFloat) -> some View {
        let m = axis.max
        if !move {
            RadioKnob("ANGLE", value: angle, lo: -m, hi: m, step: 0.5, size: size, format: degText) { v in
                if axis == .tilt { tiltAngle = v } else { rollAngle = v }
            }
        } else {
            RadioKnob("START", value: current.start, lo: -m, hi: m, step: 0.5, size: size, format: degText) { v in
                var c = current; c.start = v; setCurrent(c)
            }
            RadioKnob("END", value: current.end, lo: -m, hi: m, step: 0.5, size: size, format: degText) { v in
                var c = current; c.end = v; setCurrent(c)
            }
            RadioKnob("TIME", value: Float(min(max(current.secs, 1), 30)), lo: 1, hi: 30, step: 1, size: size,
                      format: { "\(Int($0.rounded())) s" }) { v in
                var c = current; c.secs = Int(v.rounded()); setCurrent(c)
            }
        }
    }

    private var setKey: some View {
        PianoKey(move ? "SET" : "OK", wide: true) {
            if move {
                mover.store.setMove(axis, current)
                mover.store.axis = axis
                mover.store.moveOn = true
                mover.armMove(axis, start: current.start, done: "Ready: record to start the move")
            } else {
                mover.store.rollAngle = rollAngle
                mover.store.tiltAngle = tiltAngle
                mover.goTo(angle, axis)
            }
            onClose()
        }
    }

    private var saveKey: some View {
        PianoKey("SAVE", enabled: move) {
            let p = MovePreset(axis: axis, start: current.start, end: current.end, secs: current.secs)
            mover.store.presets = mover.store.presets.filter { $0 != p } + [p]
            mover.camera?.message = "Move saved"
        }
    }

    private var loadKey: some View {
        PianoKey("LOAD", enabled: !presets.isEmpty) { loading = true }
    }

    private var cancelKey: some View { PianoKey("CANCEL", action: onClose) }

    private var hint: String {
        if move && axis == .pan { return "Pan: + looks right, − left, from where the camera looks when you press SET or USE. Record runs it back and forth." }
        if move { return "Record runs the move, back and forth, until you stop. The record button turns blue." }
        return axis == .tilt ? "Tilt: + points the camera up, − down." : "Roll: + raises the horizon's right side."
    }

    // MARK: LOAD: the saved moves

    @ViewBuilder private func savedMoves(_ portrait: Bool) -> some View {
        VStack(spacing: 0) {
            Text("SAVED MOVES")
                .font(s.font(15, .semibold))
                .tracking(s.tracking(0.3, sp: 15))
                .foregroundStyle(Color.brass)
            Spacer().frame(height: s(10))
            // Up to 250dp tall, then it scrolls.
            ViewThatFits(in: .vertical) {
                presetList(portrait)
                ScrollView(.vertical, showsIndicators: false) { presetList(portrait) }
                    .frame(height: s(250))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: s(250))
            Spacer().frame(height: s(14))
            PianoKey("BACK") { loading = false }
        }
    }

    private func presetList(_ portrait: Bool) -> some View {
        VStack(spacing: s(10)) {
            ForEach(presets) { p in
                if portrait {
                    VStack(spacing: s(8)) {
                        HStack(spacing: s(14)) { miniDial(p); info(p, width: 150) }
                        HStack(spacing: s(12)) { presetKeys(p) }
                    }
                } else {
                    HStack(spacing: s(14)) {
                        miniDial(p)
                        info(p, width: 190)
                        presetKeys(p)
                    }
                }
            }
        }
    }

    private func miniDial(_ p: MovePreset) -> some View {
        DialWindow(axis: p.axis, move: true, angle: 0, start: p.start, end: p.end, secs: p.secs, width: 138, height: 90, caption: false)
    }

    private func info(_ p: MovePreset, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(p.axis.tag).font(s.font(13)).tracking(s.tracking(0.2, sp: 13)).foregroundStyle(Color.brass)
            Text("\(degText(p.start)) → \(degText(p.end))").font(s.font(16)).foregroundStyle(Color.amber)
            Text("\(p.secs) s each way").font(s.font(13)).foregroundStyle(Color.walnutHint)
        }
        .frame(width: s(width), alignment: .leading)
    }

    @ViewBuilder private func presetKeys(_ p: MovePreset) -> some View {
        // USE: set at once and close: the gimbal goes to the start, ready to record.
        PianoKey("USE") {
            mover.store.setMove(p.axis, AxisMove(start: p.start, end: p.end, secs: p.secs))
            mover.store.axis = p.axis
            mover.store.moveOn = true
            mover.armMove(p.axis, start: p.start, done: "Ready: record to start the move")
            onClose()
        }
        // EDIT: onto the knobs; SAVE then keeps it as a new move.
        PianoKey("EDIT") {
            axis = p.axis
            move = true
            setCurrent(AxisMove(start: p.start, end: p.end, secs: p.secs))
            loading = false
        }
        Button { askDelete = p } label: {
            CineIcon(.bin).frame(width: s(40), height: s(40)).contentShape(Circle())
        }
        .buttonStyle(CinePressStyle())
    }

    /// Delete a saved move: its own small popup over the list (RollDialog.kt:214-237).
    private func deletePopup(_ p: MovePreset) -> some View {
        CineScrim(color: .scrim, onTapOutside: { askDelete = nil }) {
            VStack(spacing: 0) {
                Text("Delete this move?").font(s.font(17, .semibold)).foregroundStyle(Color.brass)
                Text(p.label).font(s.font(14)).foregroundStyle(Color.amber)
                    .padding(.top, s(6)).padding(.bottom, s(16))
                HStack(alignment: .top, spacing: s(12)) {
                    PianoKey("DELETE") {
                        let wasLast = mover.store.presets.count <= 1
                        mover.store.presets.removeAll { $0 == p }
                        askDelete = nil
                        if wasLast { loading = false }
                    }
                    PianoKey("KEEP") { askDelete = nil }
                }
            }
            .radioPanel(radius: 16, h: 26, v: 20)
        }
    }
}

/// Old entry point, kept so CameraScreen builds until it shows MovesDialog as an overlay itself.
struct MovesSheet: View {
    @ObservedObject var mover: Mover
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        MovesDialog(mover: mover) { dismiss() }
            .presentationBackground(.clear)
    }
}

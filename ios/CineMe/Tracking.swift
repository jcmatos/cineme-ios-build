import AVFoundation
import SwiftUI
import Vision

// Subject tracking (the Android app's TrackController.kt, Tracker.kt, ArmsTrigger.kt): Track ->
// drag a box (or tap) on the picture -> the gimbal turns to keep the subject where it was picked.
// The Android app matches patterns in a grey copy of the preview; here Vision's VNTrackObjectRequest
// follows the box in the camera's own frames (AVCaptureVideoDataOutput, next to the movie output).
// Each frame: error = subject - anchor (0..1 of the picture). A dead zone ignores small drift, a
// low-pass filter (Smoothness) and a ramp soften it, and the result is a joystick speed, smaller
// when zoomed in, capped by Max speed. Picture x drives pan, y tilt.

final class Tracker: ObservableObject {
    enum Mode { case idle, selecting, tracking, lost }
    /// Arms trigger: off, waiting for both arms up, or recording + tracking.
    enum Arms { case off, armed, running }

    @Published private(set) var mode: Mode = .idle
    /// Where the subject is now, 0..1 of the picture (y down).
    @Published private(set) var box: CGRect? = nil
    /// Where it was picked: the spot the gimbal keeps it at.
    @Published private(set) var anchor: CGPoint? = nil
    /// Width / height of the frames (upright as on screen); nil until the first frame.
    @Published private(set) var frameAspect: CGFloat? = nil
    @Published private(set) var arms: Arms = .off
    /// Arms up and being held: where the body is (0..1 of the picture).
    @Published private(set) var armsSeen: CGPoint? = nil

    // Settings (as on Android: Settings > Tracking).
    @Published var smooth: Int = Tracker.int("trackSmooth", 6) { didSet { UserDefaults.standard.set(smooth, forKey: "trackSmooth") } }
    @Published var speed: Int = Tracker.int("trackSpeed", 5) { didSet { UserDefaults.standard.set(speed, forKey: "trackSpeed") } }
    /// 0 off, 1 small, 2 medium: how far the subject may drift before the gimbal moves.
    @Published var deadZone: Int = Tracker.int("trackDeadZone", 1) { didSet { UserDefaults.standard.set(deadZone, forKey: "trackDeadZone") } }
    @Published var panOnly: Bool = UserDefaults.standard.bool(forKey: "trackPanOnly") { didSet { UserDefaults.standard.set(panOnly, forKey: "trackPanOnly") } }
    @Published var invertPan: Bool = UserDefaults.standard.bool(forKey: "trackInvertPan") { didSet { UserDefaults.standard.set(invertPan, forKey: "trackInvertPan") } }
    @Published var invertTilt: Bool = UserDefaults.standard.bool(forKey: "trackInvertTilt") { didSet { UserDefaults.standard.set(invertTilt, forKey: "trackInvertTilt") } }

    weak var camera: Camera?
    weak var gimbal: Gimbal?
    weak var mover: Mover?

    private static func int(_ k: String, _ d: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? d }
    private static let gain: Float = 3
    private static let lostFrames = 12

    // Shared with the frames queue (under [lock]).
    private let lock = NSLock()
    private var active = false
    private var pending: CGRect? = nil
    private var armsWanted = false
    // Frames queue only.
    private var seq = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest? = nil
    private var lastAt: TimeInterval = 0
    private var count = 0
    private var aspectSent: CGFloat = 0
    private var armsSince: TimeInterval = 0
    private var armsLast: TimeInterval = 0
    private var armsReady = true
    private var armsDownSince: TimeInterval = 0
    private var quietUntil: TimeInterval = 0
    // Main thread only.
    private var missed = 0
    private var fx: Float = 0, fy: Float = 0
    private var outPan: Float = 0, outTilt: Float = 0
    private var minErr: Float = 0
    private var gimbalMoving = false
    private var framesOn = false

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    private func msg(_ m: String) { camera?.message = m }

    // MARK: - what the screen asks for

    /// Track key: start picking, or stop whatever is going on.
    func toggle() {
        if mode != .idle { stop(); return }
        guard canStart() else { return }
        mode = .selecting
    }

    private func canStart() -> Bool {
        guard let c = camera else { return false }
        if c.codec.isProRes { msg("Tracking works with HEVC or H.264 (not ProRes)"); return false }
        if c.timelapse != nil { msg("Not during a time-lapse"); return false }
        if mover?.running == true { mover?.stop() }
        return true
    }

    /// The box drawn on the picture (0..1, y down).
    func select(_ b: CGRect) {
        locked { pending = b; active = true }
        missed = 0; fx = 0; fy = 0; outPan = 0; outTilt = 0; minErr = 0
        box = b
        anchor = CGPoint(x: b.midX, y: b.midY)
        mode = .tracking
        gimbal?.takeControl()
        if gimbal?.state != .connected { msg("Gimbal not connected: tracking on screen only") }
        framesNeeded()
    }

    func stop() {
        locked { active = false; pending = nil }
        camera?.framesQueue.async { self.request = nil }
        if gimbalMoving || mode != .idle { gimbal?.stopMove(); gimbal?.releaseControl() }
        gimbalMoving = false
        mode = .idle
        box = nil
        anchor = nil
        framesNeeded()
    }

    /// The camera stopped sending frames (ProRes chosen).
    func framesDropped() {
        framesOn = false
        if arms != .off { arms = .off; locked { armsWanted = false }; armsSeen = nil }
        if mode != .idle { stop() }
    }

    /// Screenshot runs: a subject being followed.
    func fakeForShots(landscape: Bool) {
        frameAspect = landscape ? 16.0 / 9 : 9.0 / 16
        anchor = CGPoint(x: 0.5, y: 0.5)
        box = landscape ? CGRect(x: 0.47, y: 0.27, width: 0.14, height: 0.42) : CGRect(x: 0.38, y: 0.33, width: 0.28, height: 0.3)
        mode = .tracking
    }

    /// Frames on while tracking or the arms trigger is on, off otherwise.
    private func framesNeeded() {
        guard let c = camera else { return }
        let want = mode != .idle || arms != .off
        guard want != framesOn else { return }
        framesOn = want
        if want {
            c.onFrame = { [weak self] pb in self?.frame(pb) }
            c.useFrames(.tracking, true) { [weak self] error in
                guard let self = self, let e = error else { return }
                self.framesOn = false
                self.msg(e)
                if self.mode != .idle { self.stop() }
                if self.arms != .off { self.setArms(false) }
            }
        } else {
            c.useFrames(.tracking, false)
        }
    }

    // MARK: - frames (camera's frames queue)

    private func frame(_ pb: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        // About 15 a second, like Android (the filter and ramp are tuned for it).
        guard now - lastAt >= 0.06 else { return }
        lastAt = now
        count += 1
        let a = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(max(1, CVPixelBufferGetHeight(pb)))
        if a != aspectSent { aspectSent = a; DispatchQueue.main.async { self.frameAspect = a } }
        let (on, start, wantArms) = locked { () -> (Bool, CGRect?, Bool) in
            let s = pending
            pending = nil
            return (active, s, armsWanted)
        }
        if wantArms && count % 2 == 0 { armsCheck(pb, now) }
        guard on else { return }
        if let b = start {
            // Vision's boxes: 0..1 with y up.
            let obs = VNDetectedObjectObservation(boundingBox: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            let r = VNTrackObjectRequest(detectedObjectObservation: obs)
            r.trackingLevel = .accurate
            request = r
            seq = VNSequenceRequestHandler()
            return
        }
        guard let r = request else { return }
        do { try seq.perform([r], on: pb, orientation: .up) } catch { return }
        guard let o = r.results?.first as? VNDetectedObjectObservation else { return }
        r.inputObservation = o
        let v = o.boundingBox
        let b = CGRect(x: v.minX, y: 1 - v.maxY, width: v.width, height: v.height)
        let good = o.confidence >= 0.3
        DispatchQueue.main.async { self.update(b, good) }
    }

    // MARK: - steering (main thread)

    private func update(_ b: CGRect, _ good: Bool) {
        guard mode == .tracking || mode == .lost, let anchor = anchor, locked({ active }) else { return }
        missed = good ? 0 : missed + 1
        // Subject lost (about a second without a match): tracking turns itself off.
        if missed >= Tracker.lostFrames {
            stop()
            msg("Subject lost: tracking off")
            return
        }
        if good { box = b }
        let cur = box ?? b
        // At the very edge the box is half out of the picture: not to be trusted, so don't steer on it.
        let edge = cur.midX < 0.04 || cur.midX > 0.96 || cur.midY < 0.04 || cur.midY > 0.96
        let lost = !good || edge
        mode = lost ? .lost : .tracking
        // Turning away: the gimbal eases to a stop, but tracking goes on.
        let away = !lost && runningAway(cur, anchor)
        steer(cur, anchor, hold: lost || away)
    }

    /// If, while the gimbal turns, the subject ends up much further away than it already got, it's
    /// turning the wrong way (or the box follows the wrong thing): hold rather than spin off.
    private func runningAway(_ b: CGRect, _ anchor: CGPoint) -> Bool {
        let ex = Float(b.midX - anchor.x)
        let ey = panOnly ? 0 : Float(b.midY - anchor.y)
        let err = (ex * ex + ey * ey).squareRoot()
        let moving = abs(outPan) > 0.05 || abs(outTilt) > 0.05
        if !moving { minErr = err; return false }
        minErr = min(minErr, err)
        return err > minErr + 0.25
    }

    private func steer(_ b: CGRect, _ anchor: CGPoint, hold: Bool) {
        let dz: Float = deadZone == 0 ? 0 : deadZone == 1 ? 0.02 : 0.05
        // Soft dead zone: no jump when the error leaves it.
        func dead(_ e: Float) -> Float { abs(e) <= dz ? 0 : e - dz * (e > 0 ? 1 : -1) }
        let ex = hold ? 0 : dead(Float(b.midX - anchor.x))
        let ey = hold ? 0 : dead(Float(b.midY - anchor.y))
        // Smoothness 1 -> follows almost at once; 10 -> takes a couple of seconds.
        let sm = max(1, min(10, smooth))
        let a = 0.6 * pow(Float(0.775), Float(sm - 1))
        fx += (ex - fx) * a
        fy += (ey - fy) * a
        let maxV = Float(max(1, min(10, speed))) / 10
        let zoom = Float(camera?.lens.rawValue ?? "1") ?? 1
        let gain = Tracker.gain / max(zoom, 0.5)
        // Subject right of the anchor -> turn right. Below (y grows down) -> tilt down.
        var pan = min(max(fx * gain, -maxV), maxV)
        var tilt = min(max(-fy * gain, -maxV), maxV)
        if invertPan { pan = -pan }
        if invertTilt { tilt = -tilt }
        // Ramp: speed changes gently, so starts and stops are soft.
        let ramp = 0.15 / Float(sm)
        outPan += min(max(pan - outPan, -ramp), ramp)
        outTilt += min(max(tilt - outTilt, -ramp), ramp)
        if abs(outPan) < 0.005 && abs(outTilt) < 0.005 {
            if gimbalMoving { gimbal?.stopMove(); gimbalMoving = false }
        } else {
            gimbal?.move(pan: outPan, tilt: panOnly ? nil : outTilt)
            gimbalMoving = true
        }
    }

    // MARK: - arms trigger

    /// Settings switch. Armed: raise both arms for a second -> the light flashes once, recording and
    /// tracking start on the body seen. Again: both stop, two flashes, armed again.
    func setArms(_ on: Bool) {
        if on {
            guard arms == .off, canStart() else { return }
            arms = .armed
        } else {
            if arms == .running { stop() }
            arms = .off
            armsSeen = nil
        }
        locked { armsWanted = on }
        framesNeeded()
    }

    /// Recording stopped some other way (record button, gimbal): back to waiting.
    func recordingStopped() {
        guard arms == .running else { return }
        stop()
        arms = .armed
    }

    /// Both wrists above the head (higher than the nose and well above the shoulders) for a second.
    /// Vision's body pose, every 2nd frame. Arms must come down before they count again. Frames queue.
    private func armsCheck(_ pb: CVPixelBuffer, _ now: TimeInterval) {
        guard now > quietUntil else { return }
        let req = VNDetectHumanBodyPoseRequest()
        let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        guard (try? h.perform([req])) != nil else { return }
        guard let o = req.results?.first as? VNHumanBodyPoseObservation else {
            armsSince = 0
            if armsDownSince == 0 { armsDownSince = now }
            if now - armsDownSince > 2 { armsReady = true }
            seen(nil)
            return
        }
        func p(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let r = try? o.recognizedPoint(j), r.confidence > 0.3 else { return nil }
            return r.location   // 0..1, y up
        }
        guard let ls = p(.leftShoulder), let rs = p(.rightShoulder) else { seen(nil); armsSince = 0; return }
        let shY = (ls.y + rs.y) / 2
        let shW = max(0.02, hypot(ls.x - rs.x, ls.y - rs.y))
        let top = p(.nose)?.y ?? shY + shW * 0.6
        let lw = p(.leftWrist), rw = p(.rightWrist)
        let up = lw != nil && rw != nil && lw!.y > top && rw!.y > top && min(lw!.y, rw!.y) > shY + shW * 0.6
        let down = (lw.map { $0.y < shY } ?? true) && (rw.map { $0.y < shY } ?? true)
        if up {
            if armsSince == 0 || now - armsLast > 0.4 { armsSince = now }
            armsLast = now
            armsDownSince = 0
            seen(CGPoint(x: (ls.x + rs.x) / 2, y: 1 - shY))
            if armsReady && now - armsSince >= 1 {
                armsReady = false
                armsSince = 0
                // The torso: shoulders to hips (or one and a half shoulder widths down), y down.
                let hipY = [p(.leftHip)?.y, p(.rightHip)?.y].compactMap { $0 }.min() ?? max(0, shY - shW * 1.5)
                let x0 = max(0, min(ls.x, rs.x) - shW * 0.15), x1 = min(1, max(ls.x, rs.x) + shW * 0.15)
                let torso = CGRect(x: x0, y: 1 - shY, width: max(0.03, x1 - x0), height: max(0.03, shY - hipY))
                seen(nil)
                DispatchQueue.main.async { self.armsFired(torso) }
            }
        } else {
            if now - armsLast > 0.4 { armsSince = 0 }
            if down || armsLast == 0 || now - armsLast > 1.5 { armsReady = true }
            seen(nil)
        }
    }

    private func seen(_ p: CGPoint?) {
        DispatchQueue.main.async { if self.armsSeen != p { self.armsSeen = p } }
    }

    private func armsFired(_ torso: CGRect) {
        guard let c = camera else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch arms {
        case .armed:
            arms = .running
            quiet(until: now + 2)
            // Answer first (so the flash isn't in the clip), then record and track.
            c.blinkTorch(1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard self.arms == .running else { return }
                    if !c.recording { c.toggleRecord() }
                    self.select(torso)
                }
            }
        case .running:
            arms = .armed
            stop()
            if c.recording { c.toggleRecord() }
            quiet(until: now + 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { c.blinkTorch(2) }
        case .off:
            break
        }
    }

    /// Ignore everything until then (the phone's own flash lights the scene).
    private func quiet(until t: TimeInterval) { camera?.framesQueue.async { self.quietUntil = t } }
}

// MARK: - on the picture

/// Over the preview while tracking: drag a box (or tap) to pick the subject, then its frame follows it.
struct TrackLayer: View {
    @Environment(\.cineScale) private var sc
    @ObservedObject var tracker: Tracker
    let camera: Camera
    @State private var from: CGPoint? = nil
    @State private var to: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let landscape = geo.size.width > geo.size.height
            let aspect = tracker.frameAspect ?? (landscape ? 16.0 / 9 : 9.0 / 16)
            let pic = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: bounds)
            ZStack {
                if tracker.mode == .selecting {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if from == nil { from = v.startLocation }
                                to = v.location
                            }
                            .onEnded { v in pick(from ?? v.startLocation, v.location, pic) })
                    if let a = from, let b = to {
                        Rectangle().path(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
                            .stroke(Color.brass, style: StrokeStyle(lineWidth: sc(2), dash: [sc(12), sc(8)]))
                    }
                    if from == nil { hint("Drag a box around the subject", geo.size, landscape) }
                }
                if tracker.mode == .tracking || tracker.mode == .lost, let b = tracker.box {
                    let r = CGRect(x: pic.minX + b.minX * pic.width, y: pic.minY + b.minY * pic.height, width: b.width * pic.width, height: b.height * pic.height)
                    let lost = tracker.mode == .lost
                    // Corner brackets, like the focus frame: Ivory, Faint when lost.
                    TrackBrackets(rect: r, width: sc(2))
                        .stroke(lost ? Color.faint : Color.ivory, lineWidth: sc(2))
                        .allowsHitTesting(false)
                    if let an = tracker.anchor {
                        // Where the gimbal keeps it: a small brass cross.
                        let p = CGPoint(x: pic.minX + an.x * pic.width, y: pic.minY + an.y * pic.height)
                        let k = sc(9)
                        Path { q in
                            q.move(to: CGPoint(x: p.x - k, y: p.y)); q.addLine(to: CGPoint(x: p.x + k, y: p.y))
                            q.move(to: CGPoint(x: p.x, y: p.y - k)); q.addLine(to: CGPoint(x: p.x, y: p.y + k))
                        }
                        .stroke(Color.brass, lineWidth: sc(1.5))
                        .allowsHitTesting(false)
                    }
                    if lost { hint("Lost", geo.size, landscape) }
                }
                if let seen = tracker.armsSeen {
                    // Arms up: "hold" on the body (CameraScreen.kt:573), 52dp ring 2dp, 11sp.
                    Text("hold").font(sc.font(11)).foregroundStyle(Color.armsYellow)
                        .frame(width: sc(52), height: sc(52))
                        .overlay(Circle().stroke(Color.armsYellow, lineWidth: sc(2)))
                        .position(x: pic.minX + seen.x * pic.width, y: pic.minY + seen.y * pic.height)
                        .allowsHitTesting(false)
                }
            }
        }
        // Only while picking: otherwise taps reach the picture (focus) below.
        .allowsHitTesting(tracker.mode == .selecting)
    }

    /// Android's hint (CameraScreen.kt:816): 16sp, Plate capsule, padding 18x8, 60dp from the top
    /// (portrait: under the top keys).
    private func hint(_ text: String, _ size: CGSize, _ landscape: Bool) -> some View {
        Text(text).font(sc.font(16)).foregroundStyle(Color.ivory)
            .padding(.horizontal, sc(18)).padding(.vertical, sc(8))
            .plateCapsule()
            .fixedSize()
            .position(x: size.width / 2, y: landscape ? sc(60) + sc(18) : sc(170))
            .allowsHitTesting(false)
    }

    private func pick(_ a: CGPoint, _ b: CGPoint, _ pic: CGRect) {
        from = nil; to = nil
        guard pic.width > 0, pic.height > 0 else { return }
        var bw = abs(b.x - a.x) / pic.width
        var bh = abs(b.y - a.y) / pic.height
        if bw < 0.03 && bh < 0.03 {
            // A tap: a square of 15% of the short side around it.
            let side = 0.15 * min(pic.width, pic.height)
            bw = side / pic.width
            bh = side / pic.height
        }
        bw = max(bw, 0.03); bh = max(bh, 0.03)
        let cx = min(max(((a.x + b.x) / 2 - pic.minX) / pic.width, 0), 1)
        let cy = min(max(((a.y + b.y) / 2 - pic.minY) / pic.height, 0), 1)
        tracker.select(CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh))
        // The camera focuses on it too.
        if let layer = camera.previewLayer {
            camera.focus(at: layer.captureDevicePointConverted(fromLayerPoint: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        }
    }
}

/// The tracking frame: corner brackets a quarter of the short side long (CameraScreen.kt:795).
struct TrackBrackets: Shape {
    let rect: CGRect
    let width: CGFloat
    func path(in _: CGRect) -> Path {
        let l = rect.minX, tp = rect.minY, r = rect.maxX, bt = rect.maxY
        let len = min(rect.width, rect.height) * 0.25
        var p = Path()
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(l, tp, 1, 1), (r, tp, -1, 1), (l, bt, 1, -1), (r, bt, -1, -1)]
        for (x, y, dx, dy) in corners {
            p.move(to: CGPoint(x: x + dx * len, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * len))
        }
        return p
    }
}

/// Arms trigger: what it waits for, at the top (Android `TriggerBanner`, CameraScreen.kt:555):
/// capsule Plate + 1dp Edge, a 9dp dot pulsing 0.25..1 every 700ms (yellow waiting, Red running), 13sp.
struct ArmsBanner: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var tracker: Tracker
    var body: some View {
        if tracker.arms != .off {
            CamBanner {
                TimelineView(.animation) { tl in
                    let k = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 0.7
                    let pulse = 0.25 + 0.75 * (k <= 1 ? k : 2 - k)
                    Circle().fill(tracker.arms == .running ? Color.rec : Color.armsYellow)
                        .frame(width: s(9), height: s(9))
                        .opacity(pulse)
                }
                .frame(width: s(9), height: s(9))
                Text(tracker.arms == .running ? "Raise both arms to stop" : "Waiting: raise both arms")
            }
        }
    }
}

/// Settings > Tracking (Android rows via the settings pane helpers in SettingsSheet.swift).
struct TrackSettingsSection: View {
    @ObservedObject var tracker: Tracker
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneSliderRow("Smoothness", value: $tracker.smooth, range: 1...10, low: "Quick", high: "Smooth")
            PaneSliderRow("Max speed", value: $tracker.speed, range: 1...10, low: "Slow", high: "Fast")
            PaneOpt("Dead zone", [0, 1, 2], tracker.deadZone, title: { ["Off", "Small", "Medium"][$0] }) { tracker.deadZone = $0 }
            PaneOpt("Axes", [false, true], tracker.panOnly, title: { $0 ? "Pan only" : "Pan + tilt" }) { tracker.panOnly = $0 }
            PaneOpt("Pan direction", [false, true], tracker.invertPan, title: { $0 ? "Inverted" : "Normal" }) { tracker.invertPan = $0 }
            PaneOpt("Tilt direction", [false, true], tracker.invertTilt, title: { $0 ? "Inverted" : "Normal" }) { tracker.invertTilt = $0 }
            PaneOnOff("Arms trigger", isOn: Binding(get: { tracker.arms != .off }, set: { tracker.setArms($0) }))
            CineNote("Track: drag a box around the subject; the gimbal keeps it where you picked it. MODE on the gimbal stops it. Arms trigger: raise both arms for a second to start recording and tracking, again to stop. Not with ProRes.")
        }
    }
}

// MARK: - the rig: level, moves and tracking, wired to the camera and the gimbal

final class Rig {
    static let shared = Rig()
    let level = Level()
    let mover = Mover()
    let tracker = Tracker()
    private var attached = false
    /// The saved move spread over the running time-lapse.
    private var tlMove: MovePreset? = nil

    func attach(camera: Camera, gimbal: Gimbal) {
        guard !attached else { return }
        attached = true
        mover.camera = camera; mover.gimbal = gimbal; mover.level = level
        tracker.camera = camera; tracker.gimbal = gimbal; tracker.mover = mover
        mover.trackingBusy = { [weak self] in self?.tracker.mode != .idle }
        camera.onFramesDropped = { [weak self] in self?.tracker.framesDropped() }
        // MODE on the gimbal stops tracking (as on Android).
        gimbal.onEventAlso = { [weak self] e in if e == .mode { self?.tracker.stop() } }
        // After each photo the gimbal steps on along the move (first photo at its start, last at its end).
        camera.onTimelapseShot = { [weak self] s, total in
            guard let self = self, let m = self.tlMove, s >= 1, s < total else { return }
            self.mover.timelapseStep(m.start + (m.end - m.start) * Float(s) / Float(max(1, total - 1)))
        }
        camera.onTimelapseEnd = { [weak self] in
            guard let self = self, self.tlMove != nil else { return }
            self.tlMove = nil
            self.mover.timelapseEnd()
        }
    }

    /// Recording started or stopped: the move set runs (not in a time-lapse); the arms trigger hears of a stop.
    func recordingChanged(_ on: Bool, camera: Camera) {
        if on && camera.timelapse == nil { mover.startSweep() } else if !on { mover.stopSweep(); tracker.recordingStopped() }
    }

    /// Time-lapse START: tracking stops; with a move, first to its start, then the photos begin.
    func startTimelapse(_ plan: TimelapsePlan, _ move: MovePreset?, camera: Camera) {
        if camera.codec.isRAW { camera.message = "Time-lapse can't use ProRes RAW: pick another codec in Settings"; return }
        if tracker.mode != .idle { tracker.stop() }
        if tracker.arms != .off { tracker.setArms(false) }
        func go() { camera.startTimelapse(interval: plan.interval, total: plan.shots, fps: plan.fps) }
        guard let m = move else { go(); return }
        tlMove = m
        mover.timelapseBegin(m.axis, start: m.start)
        var waited = 0.0
        func wait() {
            if mover.running && waited < 15 {
                waited += 0.1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait() }
            } else {
                go()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { wait() }
    }
}

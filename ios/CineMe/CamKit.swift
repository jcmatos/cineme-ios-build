import AVFoundation
import SwiftUI

// Pieces of the camera screen drawn as on Android (CameraScreen.kt): the drums, the Material slider,
// the round icon keys. Sizes in Android dp through the area's scale (`s(…)`, Theme.swift).

/// Android's Blue (record while a gimbal move is set). Written out here: Moves.swift also declares
/// a `Color.moveBlue`, so the name could be ambiguous.
let camBlue = Color(argb: 0xFF3D7FE0)

// MARK: - camera helpers for the screen

extension Camera {
    /// ISO and shutter the camera uses now (auto exposure), snapped to the drum steps; nil without a camera.
    func liveExposure() -> (iso: Float, shutter: Int32)? {
        guard let dev = device else { return nil }
        let secs = CMTimeGetSeconds(dev.exposureDuration)
        let den = secs > 0 ? Int32((1 / secs).rounded()) : shutter
        let sh = shutterDenominators.min { abs($0 - den) < abs($1 - den) } ?? shutter
        let i = isoSteps.min { abs($0 - dev.iso) < abs($1 - dev.iso) } ?? iso
        return (i, sh)
    }

    /// Leaving auto exposure from a drum: start from what the camera uses now (no jump).
    func manualExposureHere() {
        guard autoExposure else { return }
        if let l = liveExposure() { iso = l.iso; shutter = l.shutter }
        autoExposure = false
    }

    /// The ISO drum's values (low to high) and the current one.
    var isoDrum: (values: [Float], index: Int) {
        let steps = isoSteps.filter { isoRange.contains($0) }
        let now = autoExposure ? (liveExposure()?.iso ?? iso) : iso
        let i = steps.indices.min { abs(steps[$0] - now) < abs(steps[$1] - now) } ?? 0
        return (steps, i)
    }

    /// The shutter drum's values, short to long (brighter lower, as on Android), and the current one.
    var shutterDrum: (values: [Int32], index: Int) {
        let steps = Array(shutterDenominators.filter { $0 >= Int32(fps) }.reversed())
        let now = autoExposure ? (liveExposure()?.shutter ?? shutter) : shutter
        let i = steps.indices.min { abs(steps[$0] - now) < abs(steps[$1] - now) } ?? 0
        return (steps, i)
    }

    /// AF lock (the lock key by the focus frame): holds the focus where it is; off = continuous AF again.
    func setFocusLock(_ on: Bool) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        if on {
            if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
        } else if autoFocus, dev.isFocusModeSupported(.continuousAutoFocus) {
            dev.focusMode = .continuousAutoFocus
        }
    }
}

// MARK: - drum

/// Android `DrumWheel` (CameraScreen.kt:1206): a drum seen edge-on, the value at the red index is
/// current, the neighbours fade away above and below. Values listed so that dragging up = brighter
/// (or farther): higher index drawn lower. 30dp of drag per step.
struct CamDrum<Side: View>: View {
    @Environment(\.cineScale) private var s
    let label: String
    let values: [String]
    let index: Int
    /// Face height in dp (196 landscape, 132 portrait).
    let height: CGFloat
    let side: Side
    let onStep: (Int) -> Void
    @State private var drag: CGFloat = 0
    @State private var lastT: CGFloat = 0
    @State private var held = false

    init(_ label: String, values: [String], index: Int, height: CGFloat, onStep: @escaping (Int) -> Void,
         @ViewBuilder side: () -> Side) {
        self.label = label
        self.values = values
        self.index = index
        self.height = height
        self.onStep = onStep
        self.side = side()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s(5)) {
            Text(label)
                .font(s.font(12)).tracking(s.tracking(0.08, sp: 12))
                .foregroundStyle(Color.dim).lineLimit(1)
                .frame(width: s(70))
            HStack(spacing: 0) {
                face.padding(.horizontal, s(4))
                side
            }
        }
    }

    private var face: some View {
        let h = s(height)
        let pitch = s(30)
        return ZStack {
            Color.drum
            // Knurled strip on the left edge.
            Canvas { ctx, size in
                let g = s(4)
                var p = Path()
                var y = -size.width
                while y < size.height {
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y + size.width))
                    p.move(to: CGPoint(x: 0, y: y + size.width)); p.addLine(to: CGPoint(x: size.width, y: y))
                    y += g
                }
                ctx.stroke(p, with: .color(Color.edge), lineWidth: 0.6)
            }
            .frame(width: s(8), height: h)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Printed values, moving with the thumb.
            ZStack {
                ForEach(-3...3, id: \.self) { k in
                    if values.indices.contains(index + k) {
                        let d = abs(k)
                        Text(values[index + k])
                            .font(s.font(d == 0 ? 19 : d == 1 ? 16 : 13, d == 0 ? .medium : .regular))
                            .foregroundStyle(d == 0 ? Color.ivory : d == 1 ? Color.drumNear : Color.faint)
                            .lineLimit(1).fixedSize()
                            .padding(.trailing, s(6))
                            .offset(y: pitch * CGFloat(k) + drag)
                    }
                }
            }
            // Fade at both ends, so the face reads as curving away.
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.drum, Color.drum.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.28)
                Spacer(minLength: 0)
                LinearGradient(colors: [Color.drum.opacity(0), Color.drum], startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.28)
            }
            // Red index mark.
            CineIcon(.drumIndex).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: s(62), height: h)
        .clipShape(cineRect(s(14)))
        .overlay(cineRect(s(14)).strokeBorder(held ? Color.brass : Color.edge, lineWidth: s(1)))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: s(2))
                .onChanged { v in
                    if !held { held = true; lastT = 0; drag = 0 }
                    drag += v.translation.height - lastT
                    lastT = v.translation.height
                    while drag <= -pitch { onStep(1); drag += pitch }
                    while drag >= pitch { onStep(-1); drag -= pitch }
                }
                .onEnded { _ in held = false; drag = 0; lastT = 0 }
        )
    }
}

extension CamDrum where Side == EmptyView {
    init(_ label: String, values: [String], index: Int, height: CGFloat, onStep: @escaping (Int) -> Void) {
        self.init(label, values: values, index: index, height: height, onStep: onStep) { EmptyView() }
    }
}

// MARK: - slider

/// The Material 3 slider Android uses (WB strip): a 16dp rounded track, Brass
/// before the thumb and Edge after it, a 4 x 44dp Ivory bar thumb with a 6dp gap each side, a small
/// stop dot at the end.
struct CamSlider: View {
    @Environment(\.cineScale) private var s
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var enabled = true
    let onChange: (Double) -> Void

    init(value: Double, in range: ClosedRange<Double>, step: Double? = nil, enabled: Bool = true, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.range = range
        self.step = step
        self.enabled = enabled
        self.onChange = onChange
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let thumbW = s(4), gap = s(6), trackH = s(16), inner = s(2)
            let span = range.upperBound - range.lowerBound
            let f = span > 0 ? CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) : 0
            let x = thumbW / 2 + (w - thumbW) * f
            let leftEnd = max(0, x - thumbW / 2 - gap)
            let rightStart = min(w, x + thumbW / 2 + gap)
            ZStack(alignment: .leading) {
                if leftEnd > 0 {
                    UnevenRoundedRectangle(topLeadingRadius: trackH / 2, bottomLeadingRadius: trackH / 2,
                                           bottomTrailingRadius: inner, topTrailingRadius: inner, style: .circular)
                        .fill(Color.brass).frame(width: leftEnd, height: trackH)
                }
                if rightStart < w {
                    UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner,
                                           bottomTrailingRadius: trackH / 2, topTrailingRadius: trackH / 2, style: .circular)
                        .fill(Color.edge).frame(width: w - rightStart, height: trackH)
                        .offset(x: rightStart)
                    if w - rightStart > trackH {
                        Circle().fill(Color.brass).frame(width: s(4), height: s(4))
                            .offset(x: w - trackH / 2 - s(2))
                    }
                }
                Capsule().fill(Color.ivory).frame(width: thumbW, height: s(44))
                    .offset(x: x - thumbW / 2)
            }
            .frame(width: w, height: g.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    guard enabled, w > thumbW else { return }
                    let k = Double(min(max((v.location.x - thumbW / 2) / (w - thumbW), 0), 1))
                    var nv = range.lowerBound + k * span
                    if let st = step, st > 0 { nv = (nv / st).rounded() * st }
                    nv = min(max(nv, range.lowerBound), range.upperBound)
                    if nv != value { onChange(nv) }
                }
            )
        }
        .frame(height: s(44))
        .opacity(enabled ? 1 : Theme.disabledAlpha)
    }
}

// MARK: - top: status pill

/// Android `TopStatus` (CameraScreen.kt:896): capsule, Plate, padding 16x5, items 14dp apart. Idle:
/// the format 14sp (0.03em), then the timecode / anamorphic badges (iPhone only), storage and
/// battery in Dim. Recording: a 9dp red dot and the time, 16sp w500.
struct CamStatusPill: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera

    var body: some View {
        HStack(spacing: s(14)) {
            if camera.recording {
                TimelineView(.periodic(from: .now, by: 0.5)) { t in
                    let sec = max(0, Int(t.date.timeIntervalSince(camera.recordStart)))
                    HStack(spacing: s(7)) {
                        Circle().fill(Color.rec).frame(width: s(9), height: s(9))
                        Text(String(format: "%02d:%02d", sec / 60, sec % 60))
                            .font(s.font(16, .medium)).monospacedDigit()
                    }
                }
            } else {
                // "4K30 HDR (Dolby Vision) · HEVC" -> "4K30 HDR HEVC" (Android: "720p30 8-bit 120M").
                let f = camera.formatText.replacingOccurrences(of: " (Dolby Vision)", with: "")
                let full = f.replacingOccurrences(of: " · ", with: " ")
                let short = f.components(separatedBy: " · ").first ?? f
                ViewThatFits(in: .horizontal) {
                    Text(full).lineLimit(1).fixedSize()
                    Text(short).lineLimit(1).fixedSize()
                    Text(short).lineLimit(1).minimumScaleFactor(0.6)
                }
                .font(s.font(14)).tracking(s.tracking(0.03, sp: 14))
            }
            ProBadges(fps: camera.fps)   // TC 14:32:08:12, ANA 2x (Timecode.swift)
            HStack(spacing: s(5)) {
                CineIcon(.storage, color: Color.dim)
                Text(camera.externalName ?? CamStatusPill.freeSpace()).lineLimit(1).fixedSize()
            }
            .font(s.font(14)).foregroundStyle(Color.dim)
            let b = CamStatusPill.battery()
            HStack(spacing: s(5)) {
                CineIcon(.battery(level: b), color: Color.dim)
                Text(b < 0 ? "" : "\(b)%").lineLimit(1).fixedSize()
            }
            .font(s.font(14)).foregroundStyle(Color.dim)
        }
        .foregroundStyle(Color.ivory)
        .padding(.horizontal, s(16)).padding(.vertical, s(5))
        .plateCapsule()
    }

    static func freeSpace() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let gb = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
        return String(format: "%.0f GB", gb)
    }

    /// 0...100, or -1 when not known (Android shows nothing then). Screenshot runs: 100.
    static func battery() -> Int {
        if Shot.screen != nil { return 100 }
        let l = UIDevice.current.batteryLevel
        return l < 0 ? -1 : Int((l * 100).rounded())
    }
}

/// Blinking light while recording, as tall as the status pill (CameraScreen.kt:887).
struct CamRecLed: View {
    @Environment(\.cineScale) private var s
    let color: Color
    let size: CGFloat
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { t in
            let on = Int(t.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle().fill(color.opacity(on ? 1 : 0.15))
                .frame(width: max(size, s(14)), height: max(size, s(14)))
        }
    }
}

// MARK: - top right row

/// Android's top-right row (CameraScreen.kt:271-317): [REC light] [trash when a move is set]
/// [upload arrow] [level pill] [moves key] [time-lapse key] [record signal] [reconnect] [G].
struct CamTopRight: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var gimbal: Gimbal
    @ObservedObject var mover: Mover
    @ObservedObject var backup: Backup
    let level: Level
    let statusHeight: CGFloat
    let onClearMove: () -> Void
    let onMoves: () -> Void
    let onTimelapse: () -> Void
    let onGimbal: () -> Void
    @AppStorage("recSignal") private var signal = Beeper.Signal.beeps.rawValue
    @State private var flash = false

    var body: some View {
        let key = max(statusHeight, s(28))
        HStack(spacing: 0) {
            if camera.recording {
                CamRecLed(color: mover.store.moveOn ? camBlue : Color.rec, size: statusHeight).padding(.trailing, s(10))
            }
            // A gimbal move is set: the trash clears it (asks first).
            if mover.store.moveOn {
                iconKey(action: onClearMove) { CineIcon(.trash) }.padding(.trailing, s(4))
            }
            if backup.busy { CineIcon(.uploading).padding(.trailing, s(8)) }
            // Tap = level the horizon; long press = the gimbal moves.
            LevelPill(level: level, mover: mover, height: statusHeight,
                      onTap: { mover.toggleLevel() }, onLongPress: onMoves)
                .padding(.trailing, s(8))
            // Saved moves: a round key as tall as the level; blue while a move is set.
            roundKey(fill: mover.store.moveOn ? camBlue.opacity(0.55) : Color.plate, size: key, action: onMoves) {
                CineIcon(.moves)
            }
            .padding(.trailing, s(6))
            // Time-lapse: red while one runs (tap stops it).
            roundKey(fill: camera.timelapse != nil ? Color.rec.opacity(0.6) : Color.plate, size: key, action: onTimelapse) {
                CineIcon(.stopwatch)
            }
            .padding(.trailing, s(6))
            // Record start / stop signal: beeps -> vibrate -> silent -> beeps.
            iconKey(action: nextSignal) {
                if signal == Beeper.Signal.vibrate.rawValue {
                    CineIcon(.vibrate)
                } else {
                    let silent = signal == Beeper.Signal.silent.rawValue
                    CineIcon(.speaker(muted: silent), color: silent ? Color.dim : Color.ivory)
                }
            }
            // Connect again (as a long press on the G); hidden while connected.
            if gimbal.state != .connected {
                iconKey(action: reconnect) { CineIcon(.refresh) }
            }
            CineGimbalBadge(connected: gimbal.state == .connected)
                .overlay(Circle().strokeBorder(Color.brass, lineWidth: flash ? s(2) : 0))
                .padding(s(6))
                .contentShape(Circle())
                .onTapGesture { Haptics.tap(); onGimbal() }
                .onLongPressGesture { Haptics.tap(); reconnect() }
                // A gimbal key pressed: the G flashes (iPhone only).
                .onChange(of: gimbal.lastKey?.1) { _, _ in
                    flash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { flash = false }
                }
        }
    }

    /// An icon in a 6dp padded round touch area (Android `.clip(CircleShape).clickable.padding(6.dp)`).
    private func iconKey<C: View>(action: @escaping () -> Void, @ViewBuilder _ icon: () -> C) -> some View {
        Button(action: action) { icon().padding(s(6)).contentShape(Circle()) }
            .buttonStyle(CinePressStyle())
    }

    /// A borderless filled circle key (moves, time-lapse).
    private func roundKey<C: View>(fill: Color, size: CGFloat, action: @escaping () -> Void, @ViewBuilder _ icon: () -> C) -> some View {
        Button(action: action) {
            icon().frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(CinePressStyle())
    }

    private func nextSignal() {
        switch Beeper.Signal(rawValue: signal) ?? .beeps {
        case .beeps: signal = Beeper.Signal.vibrate.rawValue; camera.message = "Vibrate: 1 buzz start, 2 stop"
        case .vibrate: signal = Beeper.Signal.silent.rawValue; camera.message = "Silent"
        case .silent: signal = Beeper.Signal.beeps.rawValue; camera.message = "Beeps on"
        }
    }

    private func reconnect() {
        gimbal.reconnect()
        camera.message = "Looking for the gimbal…"
    }
}

// MARK: - wheels (ISO, shutter, focus)

/// Android `Wheels` (CameraScreen.kt:1099): ISO and shutter drums with Auto under them; in MF a
/// third drum for focus with the ring key beside it. Landscape: side by side, the mic key above ISO.
/// Portrait: stacked, shorter drums.
/// Auto: tap = measure once and keep it (as Android, "Measuring…" in brass meanwhile); long press =
/// continuous auto exposure on / off (iPhone; brass border and mark while it's on, the drums show
/// what the camera picks).
struct CamWheels: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    let portrait: Bool
    let onMic: () -> Void
    let onRing: () -> Void
    @Binding var measuring: Bool

    var body: some View {
        // In auto the drums follow the camera's own values.
        TimelineView(.periodic(from: .now, by: camera.autoExposure ? 0.5 : 3600)) { _ in
            if portrait {
                // No mic key in portrait: Android has it in landscape only (CameraScreen.kt:1169).
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        iso
                        Spacer().frame(height: s(6))
                        shutter
                        Spacer().frame(height: s(8))
                        auto
                    }
                    .frame(width: s(70))
                    if !camera.autoFocus {
                        focus.padding(.top, s(10))
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: s(10)) {
                    VStack(alignment: .leading, spacing: 0) {
                        micKey.padding(.bottom, s(8))
                        HStack(spacing: s(10)) { iso; shutter }
                        Spacer().frame(height: s(8))
                        auto.frame(width: s(150))
                    }
                    // Level with the ISO and shutter drums (Android has its lock key under it, in Auto's row).
                    if !camera.autoFocus { focus.padding(.bottom, s(8 + 38)) }
                }
            }
        }
    }

    private var height: CGFloat { portrait ? 132 : 196 }

    /// Voice note about the app, above the ISO drum: 44dp Plate circle, Edge border.
    private var micKey: some View {
        CineRoundKey(size: 44, action: onMic) { CineIcon(.mic) }
            .frame(width: s(70))
    }

    private var iso: some View {
        let d = camera.isoDrum
        return CamDrum("ISO", values: d.values.map { "\(Int($0))" }, index: d.index, height: height) { dir in
            camera.manualExposureHere()
            let now = camera.isoDrum
            let i = min(max(now.index + dir, 0), now.values.count - 1)
            guard now.values.indices.contains(i) else { return }
            camera.iso = now.values[i]
            camera.setExposure()
        }
    }

    private var shutter: some View {
        let d = camera.shutterDrum
        return CamDrum("Shutter", values: d.values.map { "1/\($0)" }, index: d.index, height: height) { dir in
            camera.manualExposureHere()
            let now = camera.shutterDrum
            let i = min(max(now.index + dir, 0), now.values.count - 1)
            guard now.values.indices.contains(i) else { return }
            camera.shutter = now.values[i]
            camera.setExposure()
        }
    }

    /// Full width under the drums, 38dp, Plate capsule, Edge border (Brass while measuring / auto).
    private var auto: some View {
        let continuous = camera.autoExposure && !measuring
        return Text(measuring ? "Measuring…" : "Auto")
            .font(s.font(portrait ? 13 : 15)).tracking(s.tracking(0.1, sp: portrait ? 13 : 15))
            .foregroundStyle(measuring ? Color.brass : Color.ivory)
            .lineLimit(1).minimumScaleFactor(0.7)
            .brassMark(continuous)
            .frame(maxWidth: .infinity)
            .frame(height: s(38))
            .plateCapsule(border: camera.autoExposure ? Color.brass : Color.edge)
            .onTapGesture {
                Haptics.tap()
                measuring = true
                camera.autoOnce()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { measuring = false }
            }
            .onLongPressGesture {
                Haptics.tap()
                if camera.autoExposure { camera.manualExposureHere(); camera.message = "Exposure: manual" }
                else { camera.autoExposure = true; camera.message = "Exposure: auto" }
                camera.setExposure()
            }
    }

    /// MF: the lens position (0 near .. 1 far; iOS gives no distance) as a drum, farther lower.
    private var focus: some View {
        let steps = CamWheels.focusSteps
        let i = steps.indices.min { abs(steps[$0] - camera.focus) < abs(steps[$1] - camera.focus) } ?? 0
        return CamDrum("Focus", values: steps.map { String(format: "%.2f", $0) }, index: i, height: height, onStep: { dir in
            let now = steps.indices.min { abs(steps[$0] - camera.focus) < abs(steps[$1] - camera.focus) } ?? 0
            let j = min(max(now + dir, 0), steps.count - 1)
            camera.autoFocus = false
            camera.focus = steps[j]
            camera.setFocus()
        }) {
            // The focus ring: turn round and round, like a lens.
            CineRoundKey(size: 30, action: onRing) { CineIcon(.ringToggle) }
        }
    }

    static let focusSteps: [Float] = (0...50).map { Float($0) / 50 }
}

// MARK: - bottom bar

/// Android `ControlBar` (CameraScreen.kt:1279): pills 5dp apart: "WB 5500 K" (Brass border while
/// its strip is open), "AF MF" (chosen Ivory + brass mark, other Faint), the aperture (iPhone 18 Pro
/// only: tap = next stop), one zoom key per lens ("0.5", "1×", "2×": Ivory + mark when on, else Dim).
struct CamControlBar: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @Binding var wbOpen: Bool
    @Binding var ring: Bool

    var body: some View {
        HStack(spacing: s(5)) {
            CinePill(selected: wbOpen, action: { wbOpen.toggle() }) {
                Text("WB").font(s.font(12)).foregroundStyle(Color.dim)
                Spacer().frame(width: s(6))
                Text(verbatim: camera.autoWB ? "Auto" : "\(Int(camera.kelvin)) K")
            }
            CinePill(action: toggleFocus) {
                Text("AF").foregroundStyle(camera.autoFocus ? Color.ivory : Color.faint).brassMark(camera.autoFocus)
                Spacer().frame(width: s(8))
                Text("MF").foregroundStyle(!camera.autoFocus ? Color.ivory : Color.faint).brassMark(!camera.autoFocus)
            }
            if !camera.apertureStops.isEmpty {
                CinePill(action: nextAperture) {
                    Text("f").font(s.font(12)).foregroundStyle(Color.dim)
                    Spacer().frame(width: s(6))
                    Text(camera.aperture.map { String(format: "%.2g", $0) } ?? "Auto")
                }
            }
            ForEach(camera.lenses) { l in
                let on = camera.lens == l
                CinePill(action: {
                    guard !camera.recording else { camera.message = "Not while recording"; return }
                    camera.lens = l
                    camera.reconfigure()
                }) {
                    Text(l == .ultraWide ? "0.5" : l.rawValue + "×")
                        .foregroundStyle(on ? Color.ivory : Color.dim).brassMark(on)
                }
            }
        }
    }

    private func toggleFocus() {
        if camera.autoFocus {
            camera.manualFocusHere()
        } else {
            ring = false
            camera.autoFocus = true
            camera.setFocus()
        }
    }

    private func nextAperture() {
        let stops = camera.apertureStops
        if let a = camera.aperture, let i = stops.firstIndex(of: a) {
            camera.aperture = i + 1 < stops.count ? stops[i + 1] : nil
        } else {
            camera.aperture = stops.first
        }
        camera.message = camera.aperture.map { String(format: "f/%.2g", $0) } ?? "Aperture: auto"
        camera.setExposure()
    }
}

/// Android `WbStrip` (CameraScreen.kt:1304): above the bar, capsule Plate: "Auto" (Ivory + mark /
/// Faint), min kelvin Faint 12sp, the slider (380dp, narrower when the screen is), max kelvin, the
/// value 70dp (Faint in Auto). In Auto the slider shows the light the camera measures; moving it goes
/// manual from there.
struct CamWBStrip: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    /// Slider width in dp.
    let sliderWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let shown = camera.autoWB ? min(max(camera.measuredKelvin() ?? camera.kelvin, 2000), 10000) : camera.kelvin
            HStack(spacing: 0) {
                Text("Auto")
                    .font(s.font(15))
                    .foregroundStyle(camera.autoWB ? Color.ivory : Color.faint)
                    .brassMark(camera.autoWB)
                    .padding(.leading, s(22)).padding(.trailing, s(14)).padding(.vertical, s(22))
                    .contentShape(Rectangle())
                    .onTapGesture { Haptics.tap(); camera.autoWB.toggle(); camera.setWB() }
                Text("2000").font(s.font(12)).foregroundStyle(Color.faint)
                CamSlider(value: Double(shown), in: 2000...10000, step: 100) { v in
                    camera.kelvin = Float(v)
                    camera.autoWB = false
                    camera.setWB()
                }
                .frame(width: s(sliderWidth - 16), height: s(72))
                .padding(.horizontal, s(8))
                Text("10000").font(s.font(12)).foregroundStyle(Color.faint)
                Spacer().frame(width: s(12))
                Text(verbatim: "\(Int((shown / 100).rounded()) * 100) K")   // verbatim: no "5,600"
                    .font(s.font(15))
                    .foregroundStyle(camera.autoWB ? Color.faint : Color.ivory)
                    .lineLimit(1).fixedSize()
                    .frame(width: s(70), alignment: .leading)
            }
            .padding(.trailing, s(14))
            .plateCapsule()
            .contentShape(Capsule())
            .onTapGesture {}
        }
    }
}

// MARK: - record controls, Track, gear

/// Android `RecordControls` (CameraScreen.kt:1337): Photo / Video, 12dp, the 86dp shutter, 14dp, the
/// play key (52dp). A column at the right in landscape, a row at the bottom in portrait.
/// (Android swaps play for a trash key while recording; the iPhone can't throw a take away while it
/// records, so the play key stays, dimmed.)
struct CamRecordControls: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var mover: Mover
    let portrait: Bool
    let onPlay: () -> Void

    var body: some View {
        if portrait {
            HStack(spacing: 0) { items }
        } else {
            VStack(spacing: 0) { items }
        }
    }

    @ViewBuilder private var items: some View {
        PhotoVideoSwitch(camera: camera, photo: camera.photo)
        Spacer().frame(width: s(12), height: s(12))
        ShutterKey(camera: camera, photo: camera.photo, mover: mover)
        Spacer().frame(width: s(14), height: s(14))
        let busy = camera.recording || camera.timelapse != nil
        CineRoundKey(action: onPlay) { CineIcon(.play, color: busy ? Color.faint : Color.ivory) }
    }
}

/// Android `TrackButton` (CameraScreen.kt:699): 52dp capsule, Plate, Edge border (Brass when on),
/// "Track" 18sp Dim (Ivory + brass mark when on). Portrait: 14dp padding.
struct CamTrackKey: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var tracker: Tracker
    let wide: Bool
    var body: some View {
        let on = tracker.mode != .idle
        CineCapsuleKey(height: 52, horizontalPadding: wide ? 22 : 14, on: on, action: { tracker.toggle() }) {
            Text("Track").font(s.font(18)).foregroundStyle(on ? Color.ivory : Color.dim).brassMark(on)
        }
    }
}

// MARK: - messages

/// Android `MessageToast` (CameraScreen.kt:1048), `NotRecorded` (:1072), plus the iPhone's problem
/// line (a format the camera can't do): centre of the screen.
struct CamMessages: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera

    var body: some View {
        VStack(spacing: s(12)) {
            if let p = camera.problem {
                Text(p).font(s.font(15)).foregroundStyle(Color.ivory)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, s(16)).padding(.vertical, s(6))
                    .background(Capsule().fill(Color.rec.opacity(0.75)))
            }
            if let m = camera.message {
                // A saved clip or photo: green; a clip saved without sound: amber.
                let bg: Color = m.contains("WITHOUT SOUND") ? Color.toastNoSound
                    : (m.hasPrefix("Video saved") || m.hasPrefix("Photo saved")) ? Color.toastSaved : Color.plate
                let plain = !(m.contains("WITHOUT SOUND") || m.hasPrefix("Video saved") || m.hasPrefix("Photo saved"))
                Text(m)
                    .font(s.font(16, plain ? .regular : .semibold))
                    .foregroundStyle(plain ? Color.ivory : Color.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, s(20)).padding(.vertical, s(9))
                    .background(Capsule().fill(bg))
                    .task(id: m) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if camera.message == m { camera.message = nil }
                    }
            }
            if let n = camera.notRecorded {
                VStack(spacing: 0) {
                    Text("VIDEO NOT RECORDED").font(s.font(34, .bold))
                    Text(n).font(s.font(18)).padding(.top, s(6))
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white)
                .padding(.horizontal, s(44)).padding(.vertical, s(26))
                .background(cineRect(s(18)).fill(Color.rec))
                .contentShape(cineRect(s(18)))
                .onTapGesture { Beeper.shared.silence(); camera.notRecorded = nil }
                .task(id: n) {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if camera.notRecorded == n { camera.notRecorded = nil }
                }
            }
        }
        .padding(.horizontal, s(30))
    }
}

// MARK: - focus frame

/// Android `FocusLayer` (CameraScreen.kt:586) over the picture, AF only: tap = focus there. 72dp
/// corner brackets (arm 22%, 2dp) Ivory, Brass when locked; a 40dp lock key 10dp right of the frame;
/// a "back to centre" key 50dp left of it when off centre. With the sharp areas on (Android's
/// "Wide") the camera picks: no frame. In MF taps do nothing (the focus stays where it was set).
struct CamFocusLayer: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @ObservedObject var aids: PictureAids
    /// The tapped spot in this view's points; nil = centre.
    @State private var point: CGPoint? = nil
    @State private var locked = false

    var body: some View {
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let p = point ?? c
            let box = s(72)
            let wide = aids.zones
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { at in tapped(at) }
                if camera.autoFocus && !wide {
                    CineIcon(.focusBrackets, color: locked ? Color.brass : Color.ivory)
                        .frame(width: box, height: box)
                        .position(p)
                        .allowsHitTesting(false)
                    CineRoundKey(size: 40, border: locked ? Color.brass : Color.edge, action: toggleLock) {
                        CineIcon(.lock(closed: locked), color: locked ? Color.brass : Color.ivory)
                    }
                    .position(x: p.x + box / 2 + s(10) + s(20), y: p.y)
                    let centred = point == nil || (abs(p.x - c.x) < g.size.width * 0.02 && abs(p.y - c.y) < g.size.height * 0.02)
                    if !centred && !locked {
                        CineRoundKey(size: 40, action: { focus(c, centre: true) }) { CineIcon(.center) }
                            .position(x: p.x - box / 2 - s(50) + s(20), y: p.y)
                    }
                }
            }
        }
        .onChange(of: camera.autoFocus) { _, _ in locked = false }
        .onChange(of: camera.lens) { _, _ in locked = false; point = nil }
    }

    private func tapped(_ at: CGPoint) {
        guard camera.autoFocus, !locked else { return }
        focus(at, centre: false)
    }

    private func focus(_ at: CGPoint, centre: Bool) {
        point = centre ? nil : at
        guard let layer = camera.previewLayer else { return }
        camera.focus(at: layer.captureDevicePointConverted(fromLayerPoint: at))
    }

    private func toggleLock() {
        locked.toggle()
        camera.setFocusLock(locked)
    }
}

/// A time-lapse running (CameraScreen.kt:377): capsule Red 75%, 15sp, padding 16x6.
struct CamTimelapseBanner: View {
    @Environment(\.cineScale) private var s
    let t: TimelapseState
    var body: some View {
        let left = Double(t.total - t.shots) * t.interval
        let fps = Double(max(1, t.fps))
        Text("TIME-LAPSE  \(t.shots) / \(t.total)   \(CamTimelapseBanner.hms(left)) left   clip \(CamTimelapseBanner.hms(Double(t.shots) / fps)) of \(CamTimelapseBanner.hms(Double(t.total) / fps))")
            .font(s.font(15)).foregroundStyle(Color.ivory)
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, s(16)).padding(.vertical, s(6))
            .background(Capsule().fill(Color.rec.opacity(0.75)))
    }

    /// "1:02:05", "4:05", "0:09".
    static func hms(_ sec: Double) -> String {
        let n = max(0, Int(sec.rounded()))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }
}

/// Banner at the top (Android `TriggerBanner` style, CameraScreen.kt:555): capsule, Plate, 1dp Edge,
/// padding 14x6, 13sp. The iPhone's extra top messages use it too.
struct CamBanner<Content: View>: View {
    @Environment(\.cineScale) private var s
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: s(8)) { content() }
            .font(s.font(13)).foregroundStyle(Color.ivory)
            .lineLimit(1)
            .padding(.horizontal, s(14)).padding(.vertical, s(6))
            .plateCapsule(border: Color.edge)
    }
}

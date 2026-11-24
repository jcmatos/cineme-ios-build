import AVFoundation
import SwiftUI

// Picture aids read from the camera's frames (the Android app's HistogramSampler.kt and
// FrameAnalyzer.kt): the histogram (and its waveform and RGB parade), focus peaking (red marks on
// the sharp edges) and the sharp areas in AF (small brackets, 7 x 5 zones). The frames come from
// the camera's one frames output (Camera.FrameUse.aids), only while one of them is on, and never
// with ProRes. A small copy is read a few times a second: 160 px wide for the histogram alone,
// 640 px when peaking or the sharp areas are on (as on Android). The framing guides need no frames
// (Guides.swift).

/// One reading of the picture, for the histogram box.
struct HistogramData {
    /// Luma histogram, 64 bins, 0..1 (the tallest = 1).
    var bins: [Float]
    /// Mean luma 0..255, share of pixels blown out (any colour at the top).
    var mean: Float
    var clipped: Float
    /// Waveforms: [cols] x [levels] cells, column after column (level 0 = black), 0..1 = how many
    /// pixels of that column sit at that level. Luma, then red, green and blue for the parade.
    var luma: [Float]
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    static let cols = 64
    static let levels = 32
}

final class PictureAids: ObservableObject {
    static let shared = PictureAids()

    /// What the histogram box shows (tap it for the next).
    enum Scope: Int { case histogram, parade, waveform }

    // Settings (as on Android: Settings > Screen and Focus).
    @Published var histogram: Bool = PictureAids.bool("showHistogram", true) { didSet { save(histogram, "showHistogram"); refresh() } }
    @Published var scope: Scope = Scope(rawValue: UserDefaults.standard.integer(forKey: "scope")) ?? .histogram {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "scope") }
    }
    @Published var peaking: Bool = PictureAids.bool("peaking", false) { didSet { save(peaking, "peaking"); refresh() } }
    /// 1 (fewer marks) .. 5 (more).
    @Published var peakSens: Int = PictureAids.int("peakingSens", 3) { didSet { save(peakSens, "peakingSens"); refresh() } }
    /// 1 (faint) .. 5 (strong).
    @Published var peakAlpha: Int = PictureAids.int("peakingAlpha", 4) { didSet { save(peakAlpha, "peakingAlpha"); refresh() } }
    /// Sharp areas, in AF only.
    @Published var zones: Bool = PictureAids.bool("focusZones", false) { didSet { save(zones, "focusZones"); refresh() } }

    // What the frames show (main thread).
    @Published private(set) var hist: HistogramData? = nil
    /// Red marks, the size of the copy read (upright as on screen), to lay over the picture.
    @Published private(set) var peaks: CGImage? = nil
    /// 7 x 5, row after row: true where the picture is sharp.
    @Published private(set) var sharp: [Bool] = Array(repeating: false, count: PictureAids.zx * PictureAids.zy)
    /// Width / height of the frames; nil until the first.
    @Published private(set) var frameAspect: CGFloat? = nil
    /// Why the frame aids are off (ProRes, too much for the camera); nil = fine.
    @Published private(set) var note: String? = nil

    static let zx = 7
    static let zy = 5

    private weak var camera: Camera?
    private var framesOn = false
    /// The camera refused the frames for this format; asked again when the format changes.
    private var blocked: String? = nil

    // What the frames queue should do (under [lock]).
    private struct Wants { var hist = false, peak = false, zones = false, sens = 3, alpha = 4, maps = false }
    private let lock = NSLock()
    private var wants = Wants()
    // Frames queue only.
    private var lastAt: TimeInterval = 0
    private var lum: [UInt8] = []
    private var marks: [UInt8] = []
    private var zoneAvg = [Float](repeating: 0, count: PictureAids.zx * PictureAids.zy)
    private var aspectSent: CGFloat = 0

    private static func bool(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    private static func int(_ k: String, _ d: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? d }
    private func save(_ v: Any, _ k: String) { UserDefaults.standard.set(v, forKey: k) }

    // MARK: - on and off (main thread)

    func attach(_ c: Camera) {
        guard camera == nil else { return }
        camera = c
        c.onAidFrame = { [weak self] pb in self?.frame(pb) }
        c.onAidsDropped = { [weak self] why in self?.dropped(why) }
        refresh()
    }

    var anyOn: Bool { histogram || peaking || zones || ExposureMaps.shared.anyOn }

    /// Frames on when an aid needs them, off otherwise. Call when a setting, the codec or AF/MF changes.
    func refresh() {
        guard let c = camera, Shot.screen == nil else { return }
        let zonesNow = zones && c.autoFocus
        let maps = ExposureMaps.shared.anyOn
        let any = histogram || peaking || zonesNow || maps
        let proRes = c.codec.isProRes
        lock.lock()
        wants = Wants(hist: histogram, peak: peaking, zones: zonesNow, sens: peakSens, alpha: peakAlpha, maps: maps)
        lock.unlock()
        note = proRes ? "Off with ProRes" : blocked.map { "Off: \($0)" }
        let want = any && !proRes && blocked == nil
        ExposureMaps.shared.update(look: c.look, frames: want)
        if !histogram || !want { hist = nil }
        if !peaking || !want { peaks = nil }
        if !zonesNow || !want { sharp = Array(repeating: false, count: PictureAids.zx * PictureAids.zy) }
        guard want != framesOn else { return }
        framesOn = want
        c.useFrames(.aids, want) { [weak self] error in
            guard let self = self, let e = error else { return }
            self.dropped(e)
        }
    }

    /// A new format: frames the camera refused may work now.
    func formatChanged() {
        guard blocked != nil else { return }
        blocked = nil
        refresh()
    }

    private func dropped(_ why: String) {
        framesOn = false
        blocked = why
        refresh()
    }

    /// Screenshot runs: what a real picture would give.
    func fakeForShots(_ what: String, landscape: Bool) {
        frameAspect = landscape ? 16.0 / 9 : 9.0 / 16
        switch what {
        case "histogram":
            histogram = true
            hist = PictureAids.fakeHistogram()
        case "peaking":
            peaking = true
            zones = true
            peaks = PictureAids.fakePeaks(landscape: landscape)
            var z = Array(repeating: false, count: PictureAids.zx * PictureAids.zy)
            for i in [17, 18, 24, 25, 10] { z[i] = true }
            sharp = z
        default: break
        }
    }

    // MARK: - frames (camera's frames queue)

    private func frame(_ pb: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let w = wants
        lock.unlock()
        guard w.hist || w.peak || w.zones || w.maps else { return }
        // Histogram ~7 a second (as Android); peaking and sharp areas ~12.
        guard now - lastAt >= (w.peak || w.zones || w.maps ? 0.08 : 0.14) else { return }
        lastAt = now
        analyze(pb, w)
    }

    private static let videoLUT: [UInt8] = (0..<256).map { UInt8(max(0, min(255, ($0 - 16) * 255 / 219))) }
    private static let fullLUT: [UInt8] = (0..<256).map { UInt8($0) }

    private func analyze(_ pb: CVPixelBuffer, _ w: Wants) {
        let deep: Bool, full: Bool
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: deep = false; full = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: deep = false; full = true
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: deep = true; full = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: deep = true; full = true
        default: return
        }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let fw = CVPixelBufferGetWidthOfPlane(pb, 0), fh = CVPixelBufferGetHeightOfPlane(pb, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        guard fw >= 64, fh >= 64 else { return }

        // The small copy: long side 640 (peaking, zones) or 160 (histogram alone).
        let long = w.peak || w.zones || w.maps ? 640 : 160
        let W = fw >= fh ? long : max(16, long * fw / fh)
        let H = fw >= fh ? max(16, long * fh / fw) : long
        let n = W * H
        if lum.count != n { lum = [UInt8](repeating: 0, count: n) }
        // Each pixel of the copy: the mean of 4 camera pixels spread over its cell (a little smoothing,
        // as a scaled copy would have; less noise in the peaking).
        let lut = full ? PictureAids.fullLUT : PictureAids.videoLUT
        let half = max(1, fw / W / 2)
        lum.withUnsafeMutableBufferPointer { out in
            lut.withUnsafeBufferPointer { lut in
                for j in 0..<H {
                    let sy = min(j * fh / H, fh - 1 - half)
                    let r0 = yBase + sy * yRow, r1 = yBase + (sy + half) * yRow
                    let o = j * W
                    if deep {
                        let a = r0.assumingMemoryBound(to: UInt16.self), b = r1.assumingMemoryBound(to: UInt16.self)
                        for i in 0..<W {
                            let sx = min(i * fw / W, fw - 1 - half)
                            let s = Int(a[sx]) + Int(a[sx + half]) + Int(b[sx]) + Int(b[sx + half])
                            out[o + i] = lut[s >> 10]
                        }
                    } else {
                        let a = r0.assumingMemoryBound(to: UInt8.self), b = r1.assumingMemoryBound(to: UInt8.self)
                        for i in 0..<W {
                            let sx = min(i * fw / W, fw - 1 - half)
                            let s = Int(a[sx]) + Int(a[sx + half]) + Int(b[sx]) + Int(b[sx + half])
                            out[o + i] = lut[s >> 2]
                        }
                    }
                }
            }
        }

        // Zebras and false colour (ExposureMaps.swift) from the same copy.
        if w.maps { lum.withUnsafeBufferPointer { ExposureMaps.shared.process($0, W, H) } }
        let aspect = CGFloat(fw) / CGFloat(fh)
        let h: HistogramData? = w.hist ? scopes(W, H, fw, fh, cBase, cRow, deep: deep, full: full) : nil
        let (img, z): (CGImage?, [Bool]?) = w.peak || w.zones ? edges(W, H, w) : (nil, nil)
        let sendAspect = aspect != aspectSent
        aspectSent = aspect
        DispatchQueue.main.async {
            if sendAspect { self.frameAspect = aspect }
            // Only what's still wanted (a setting may have changed meanwhile).
            if let h = h, self.histogram, self.framesOn { self.hist = h }
            if self.peaking, self.framesOn { self.peaks = img }
            if let z = z, self.zones, self.framesOn, z != self.sharp { self.sharp = z }
        }
    }

    /// Histogram, waveform and parade from ~160 px across of the copy (colours from the chroma plane).
    private func scopes(_ W: Int, _ H: Int, _ fw: Int, _ fh: Int, _ cBase: UnsafeMutableRawPointer, _ cRow: Int,
                           deep: Bool, full: Bool) -> HistogramData {
        let cols = HistogramData.cols, levels = HistogramData.levels
        var bins = [Int](repeating: 0, count: 64)
        var wl = [Int](repeating: 0, count: cols * levels)
        var wr = wl, wg = wl, wb = wl
        var sum = 0, clipped = 0, count = 0, rows = 0
        let step = max(1, W / 160)
        let k: Float = full ? 1 : 255.0 / 224.0
        let fwHalf = max(1, fw / 2), fhHalf = max(1, fh / 2)
        func clamp(_ v: Float) -> Int { Int(max(0, min(255, v))) }
        lum.withUnsafeBufferPointer { l in
            for j in stride(from: 0, to: H, by: step) {
                rows += 1
                let cy = min(j * fh / H / 2, fhHalf - 1)
                let crow = cBase + cy * cRow
                for i in stride(from: 0, to: W, by: step) {
                    let y = Int(l[j * W + i])
                    let cx = min(i * fw / W / 2, fwHalf - 1)
                    let cb: Float, cr: Float
                    if deep {
                        let p = crow.assumingMemoryBound(to: UInt16.self)
                        cb = Float(p[cx * 2] >> 8); cr = Float(p[cx * 2 + 1] >> 8)
                    } else {
                        let p = crow.assumingMemoryBound(to: UInt8.self)
                        cb = Float(p[cx * 2]); cr = Float(p[cx * 2 + 1])
                    }
                    // BT.709 colours (close enough for a scope, also for HDR and Log pictures).
                    let u = (cb - 128) * k, v = (cr - 128) * k, yf = Float(y)
                    let r = clamp(yf + 1.5748 * v), g = clamp(yf - 0.1873 * u - 0.4681 * v), b = clamp(yf + 1.8556 * u)
                    bins[y >> 2] += 1
                    sum += y
                    count += 1
                    if r >= 250 || g >= 250 || b >= 250 { clipped += 1 }
                    let c = (i * cols / W) * levels
                    wl[c + (y >> 3)] += 1; wr[c + (r >> 3)] += 1; wg[c + (g >> 3)] += 1; wb[c + (b >> 3)] += 1
                }
            }
        }
        let top = Float(max(1, bins.max() ?? 1))
        // A cell is "full" when a quarter of its column's pixels sit there (as Android).
        let fullCell = max(1, Float(rows) / 4)
        func norm(_ a: [Int]) -> [Float] { a.map { min(1, Float($0) / fullCell) } }
        return HistogramData(bins: bins.map { Float($0) / top }, mean: Float(sum) / Float(max(1, count)),
                             clipped: Float(clipped) / Float(max(1, count)),
                             luma: norm(wl), red: norm(wr), green: norm(wg), blue: norm(wb))
    }

    /// Fine-scale edge strength |4c - up - down - left - right| (out-of-focus edges are soft): strong
    /// ones are marked red; the zones count them. Thresholds and colours as on Android (640 px copy).
    private func edges(_ W: Int, _ H: Int, _ w: Wants) -> (CGImage?, [Bool]?) {
        let thr = [120, 95, 75, 58, 44][min(max(w.sens, 1), 5) - 1]
        let a = [0x50, 0x80, 0xB0, 0xD8, 0xFF][min(max(w.alpha, 1), 5) - 1]
        // Premultiplied red (0xFF2020) at that strength.
        let pr = UInt8(255 * a / 255), pg = UInt8(0x20 * a / 255), pa = UInt8(a)
        let zx = PictureAids.zx, zy = PictureAids.zy
        var zoneCount = [Int](repeating: 0, count: zx * zy)
        if w.peak {
            if marks.count != W * H * 4 { marks = [UInt8](repeating: 0, count: W * H * 4) }
            marks.withUnsafeMutableBytes { m in _ = memset(m.baseAddress!, 0, m.count) }
        }
        lum.withUnsafeBufferPointer { l in
            marks.withUnsafeMutableBufferPointer { m in
                for y in 1..<(H - 1) {
                    let row = y * W
                    let zr = (y * zy / H) * zx
                    for x in 1..<(W - 1) {
                        let i = row + x
                        let c = Int(l[i])
                        let lap = abs(4 * c - Int(l[i - 1]) - Int(l[i + 1]) - Int(l[i - W]) - Int(l[i + W]))
                        // Noise in the shadows makes small specks: ask for more there.
                        guard lap > thr + (c < 40 ? thr / 2 : 0) else { continue }
                        zoneCount[zr + x * zx / W] += 1
                        if w.peak {
                            let p = i * 4
                            m[p] = pr; m[p + 1] = pg; m[p + 2] = pg; m[p + 3] = pa
                        }
                    }
                }
            }
        }
        var img: CGImage? = nil
        if w.peak, let provider = CGDataProvider(data: Data(marks) as CFData) {
            img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard w.zones else { return (img, nil) }
        // In focus: a fair share of sharp pixels, and close to the sharpest zone. While the camera
        // moves (motion blur) or refocuses nothing is sharp: the last zones stay.
        let area = (W / zx) * (H / zy)
        let top = zoneCount.max() ?? 0
        guard top > area / 150 else { return (img, nil) }
        for i in zoneAvg.indices {
            let on = zoneCount[i] > area / 150 && Float(zoneCount[i]) >= Float(top) * 0.45
            zoneAvg[i] = zoneAvg[i] * 0.5 + (on ? 0.5 : 0)
        }
        return (img, zoneAvg.map { $0 > 0.4 })
    }

    // MARK: - screenshot data

    private static func fakeHistogram() -> HistogramData {
        let cols = HistogramData.cols, levels = HistogramData.levels
        // A scene with dark shadows, mid tones and a bright sky on the right.
        func bump(_ x: Float, _ at: Float, _ width: Float, _ height: Float) -> Float {
            let d = (x - at) / width
            return height * exp(-d * d)
        }
        let bins: [Float] = (0..<64).map { i -> Float in
            let x = Float(i)
            let v: Float = bump(x, 14, 7, 0.55) + bump(x, 30, 9, 0.9) + bump(x, 52, 4, 0.45)
            return min(1, v + 0.02)
        }
        func wave(_ shift: Float) -> [Float] {
            var a = [Float](repeating: 0, count: cols * levels)
            for c in 0..<cols {
                let sky: Float = c > 40 ? 24 : 15
                let centre = sky + shift + 3 * sin(Float(c) / 5)
                for l in 0..<levels {
                    let d = Float(l) - centre
                    a[c * levels + l] = max(0, min(1, exp(-d * d / 6) + (l < 6 ? 0.25 : 0)))
                }
            }
            return a
        }
        return HistogramData(bins: bins, mean: 118, clipped: 0.02, luma: wave(0), red: wave(1.5), green: wave(0), blue: wave(-2))
    }

    private static func fakePeaks(landscape: Bool) -> CGImage? {
        let W = landscape ? 640 : 360, H = landscape ? 360 : 640
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setStrokeColor(red: 1, green: 0.125, blue: 0.125, alpha: 0.85)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        // A head and shoulders in the middle, sharp; the rest soft (no marks).
        let cx = CGFloat(W) / 2, cy = CGFloat(H) * 0.55
        let s = CGFloat(min(W, H))
        ctx.strokeEllipse(in: CGRect(x: cx - s * 0.11, y: cy + s * 0.05, width: s * 0.22, height: s * 0.28))
        ctx.strokeEllipse(in: CGRect(x: cx - s * 0.07, y: cy + s * 0.14, width: s * 0.05, height: s * 0.025))
        ctx.strokeEllipse(in: CGRect(x: cx + s * 0.02, y: cy + s * 0.14, width: s * 0.05, height: s * 0.025))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: cx - s * 0.3, y: 0))
        body.addCurve(to: CGPoint(x: cx, y: cy + s * 0.02), control1: CGPoint(x: cx - s * 0.28, y: cy - s * 0.1), control2: CGPoint(x: cx - s * 0.15, y: cy))
        body.addCurve(to: CGPoint(x: cx + s * 0.3, y: 0), control1: CGPoint(x: cx + s * 0.15, y: cy), control2: CGPoint(x: cx + s * 0.28, y: cy - s * 0.1))
        ctx.addPath(body)
        ctx.strokePath()
        return ctx.makeImage()
    }
}

/// Wires the picture aids to the camera (in the camera screen, so its body stays small).
struct AidsHook: View {
    @ObservedObject var camera: Camera
    let aids = PictureAids.shared
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                aids.attach(camera)
                // Screenshot runs: a histogram as a real picture would give (the simulator has no camera).
                if Shot.screen != nil { aids.fakeForShots("histogram", landscape: Shot.orientation != "portrait") }
            }
            .onChange(of: camera.codec) { _, c in
                aids.refresh()
                if c.isProRes && aids.anyOn { camera.message = "Histogram and peaking are off with ProRes" }
            }
            .onChange(of: camera.autoFocus) { _, _ in aids.refresh() }
            // Zebras and false colour read Log differently.
            .onChange(of: camera.look) { _, _ in aids.refresh() }
            .onChange(of: camera.formatText) { _, _ in aids.formatChanged() }
    }
}

import AVFoundation
import SwiftUI

// Zebras and false colour, from the picture aids' frames: PictureAids (Aids.swift) makes the small
// copy of the picture (640 px long side, upright as on screen) and hands its brightness to
// ExposureMaps.process. Off with ProRes, like the other frame aids ("Off with ProRes" shows).
//
// Both read the picture as a normal (Rec. 709) picture would show it, in IRE (0 = black, 100 = white):
// - SDR: the signal as it is.
// - HDR (HLG): the signal as it is too. HLG is made to look right on a normal screen: 18% grey sits
//   near 38, skin near 50, and 95-100 is the brightest the clip holds (about to clip).
// - Apple Log and Apple Log 2: the flat Log signal is first turned back into light (Apple's Apple Log
//   curve; Log 2 is taken to use the same curve, its colours are wider) and then into a normal
//   picture, with the top of the Log range rolled into 80-100. So 18% grey is green (41), skin is
//   pink, and yellow / red are only the top stop or so of the Log range (about to clip).
// The frames output asks for 8-bit video range (also from 10-bit HDR and Log formats; 10-bit frames
// are read too, Aids.swift): the copy keeps the picture's curve, so this works on any format.

final class ExposureMaps: ObservableObject {
    static let shared = ExposureMaps()

    /// The zebra levels offered, IRE; 0 = off.
    static let zebraLevels = [0, 70, 75, 80, 85, 90, 95, 100]

    // Settings (Settings > Exposure).
    @Published var zebra: Int = ExposureMaps.int("zebraLevel", 0) {
        didSet { UserDefaults.standard.set(zebra, forKey: "zebraLevel"); PictureAids.shared.refresh() }
    }
    @Published var falseColour: Bool = UserDefaults.standard.bool(forKey: "falseColour") {
        didSet { UserDefaults.standard.set(falseColour, forKey: "falseColour"); PictureAids.shared.refresh() }
    }

    // What the frames show (main thread), the size of the copy read.
    /// White where the picture is at or above the zebra level (gray image: a mask for the stripes).
    @Published private(set) var zebraMask: CGImage? = nil
    /// The whole picture in false colour (opaque).
    @Published private(set) var colourMap: CGImage? = nil

    var anyOn: Bool { zebra > 0 || falseColour }

    // What the frames queue should do (under [lock]).
    private struct Wants { var zebra = 0, colour = false, look = Look.sdr, frames = false }
    private let lock = NSLock()
    private var wants = Wants()

    private static func int(_ k: String, _ d: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? d }

    // MARK: - bands

    /// One false colour band, IRE [from, to).
    struct Band {
        let from: Float
        let to: Float
        let r: UInt8, g: UInt8, b: UInt8
        let label: String
        var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    }

    /// The usual monitor bands: black clip, dark, 18% grey, skin, near white, clipped. In between: grey.
    static let bands: [Band] = [
        Band(from: -1, to: 5, r: 130, g: 40, b: 185, label: "<5"),      // purple: crushed black
        Band(from: 5, to: 13, r: 40, g: 105, b: 255, label: "10"),      // blue: dark, still detail
        Band(from: 38, to: 46, r: 60, g: 200, b: 75, label: "41"),      // green: 18% grey
        Band(from: 52, to: 58, r: 255, g: 135, b: 185, label: "55"),    // pink: skin
        Band(from: 92, to: 99, r: 255, g: 225, b: 30, label: "95"),     // yellow: near white
        Band(from: 99, to: 1000, r: 235, g: 30, b: 30, label: "99+"),   // red: clipped
    ]
    /// RGB per band index (index 0 = no band, unused).
    private static let palette: [UInt8] = [0, 0, 0] + bands.flatMap { [$0.r, $0.g, $0.b] }

    // MARK: - picture level per look

    /// The copy's value (0 = black, 255 = white: video range 16-235 spread out) as IRE in a normal picture.
    static func ire(_ l: Int, _ look: Look) -> Float {
        let s = Float(l) / 255
        switch look {
        case .sdr, .hdr: return s * 100
        case .log, .log2: return displayIRE(appleLogToLight(s))
        }
    }

    // Apple Log (Apple's "Apple Log Profile" white paper): light R (1 = 100% reflectance) to signal P
    // (0..1 over the video range): P = c (R - R0)^2 below Rt, P = g log2(R + b) + d above.
    private static let logR0: Float = -0.05641088, logRt: Float = 0.01, logC: Float = 47.28711236
    private static let logB: Float = 0.00964052, logG: Float = 0.08550479, logD: Float = 0.69336945

    private static func appleLogToLight(_ p: Float) -> Float {
        let pt = logC * (logRt - logR0) * (logRt - logR0)   // 0.2086
        if p >= pt { return powf(2, (p - logD) / logG) - logB }
        if p > 0 { return (p / logC).squareRoot() + logR0 }
        return logR0
    }

    /// Light (1 = 100% reflectance) to a normal picture's IRE: the Rec. 709 curve up to 80 IRE (64%
    /// reflectance), then the rest of the Log range (up to its top, about 12 = 6 stops over 18% grey)
    /// rolled into 80-100.
    private static func displayIRE(_ r: Float) -> Float {
        if r <= 0 { return 0 }
        if r < 0.018 { return 4.5 * r * 100 }
        let knee: Float = 0.64
        if r < knee { return (1.099 * powf(r, 0.45) - 0.099) * 100 }
        let top = appleLogToLight(1)
        return min(100, 80 + 20 * log2f(r / knee) / log2f(top / knee))
    }

    // MARK: - on and off (main thread)

    /// From PictureAids.refresh: the camera's look, and whether the frames run for the aids.
    func update(look: Look, frames: Bool) {
        lock.lock()
        wants = Wants(zebra: zebra, colour: falseColour, look: look, frames: frames)
        lock.unlock()
        if !frames || zebra == 0 { zebraMask = nil }
        if !frames || !falseColour { colourMap = nil }
    }

    /// Screenshot runs: a made-up scene (sky with a sun, a wall, a face, a grey card, dark ground).
    func fakeForShots(_ what: String, landscape: Bool) {
        switch what {
        case "zebras": zebra = 95; falseColour = false
        case "falsecolour": zebra = 0; falseColour = true
        default: return
        }
        let W = landscape ? 640 : 360, H = landscape ? 360 : 640
        let lum = ExposureMaps.fakeScene(W, H)
        let (z, c) = lum.withUnsafeBufferPointer { render($0, W, H, look: .sdr, zebra: zebra, colour: falseColour) }
        zebraMask = z
        colourMap = c
    }

    // MARK: - frames (camera's frames queue)

    /// The copy's brightness, W x H, row after row (PictureAids.analyze).
    func process(_ lum: UnsafeBufferPointer<UInt8>, _ W: Int, _ H: Int) {
        lock.lock()
        let w = wants
        lock.unlock()
        guard w.frames, w.zebra > 0 || w.colour else { return }
        let (z, c) = render(lum, W, H, look: w.look, zebra: w.zebra, colour: w.colour)
        DispatchQueue.main.async {
            // Only what's still wanted (a setting may have changed meanwhile).
            self.lock.lock()
            let now = self.wants
            self.lock.unlock()
            guard now.frames else { return }
            if now.zebra > 0, z != nil { self.zebraMask = z }
            if now.colour, c != nil { self.colourMap = c }
        }
    }

    private struct Tables { var zebra: [UInt8] = [], band: [UInt8] = [], grey: [UInt8] = [] }
    // Frames queue (or main in screenshot runs, which have no frames).
    private var tables = Tables()
    private var tablesLook: Look? = nil
    private var tablesZebra = -1

    /// 256 entries each: zebra on (255) or not, band index (0 = none), grey for the parts in no band.
    private func tablesFor(_ look: Look, _ zebra: Int) -> Tables {
        if look != tablesLook || zebra != tablesZebra {
            var z = [UInt8](repeating: 0, count: 256), b = z, g = z
            for l in 0..<256 {
                let v = ExposureMaps.ire(l, look)
                z[l] = zebra > 0 && v >= Float(zebra) ? 255 : 0
                b[l] = UInt8((ExposureMaps.bands.firstIndex { v >= $0.from && v < $0.to }).map { $0 + 1 } ?? 0)
                // A little darker than the picture, so the colours stand out.
                g[l] = UInt8(max(0, min(255, v * 2.55 * 0.85)))
            }
            tables = Tables(zebra: z, band: b, grey: g)
            tablesLook = look
            tablesZebra = zebra
        }
        return tables
    }

    private func render(_ lum: UnsafeBufferPointer<UInt8>, _ W: Int, _ H: Int, look: Look, zebra: Int, colour: Bool) -> (CGImage?, CGImage?) {
        let n = W * H
        guard n > 0, lum.count >= n else { return (nil, nil) }
        let t = tablesFor(look, zebra)
        var z: CGImage? = nil, c: CGImage? = nil
        if zebra > 0 {
            var mask = [UInt8](repeating: 0, count: n)
            mask.withUnsafeMutableBufferPointer { m in
                t.zebra.withUnsafeBufferPointer { zt in
                    for i in 0..<n { m[i] = zt[Int(lum[i])] }
                }
            }
            z = ExposureMaps.image(mask, W, H, gray: true)
        }
        if colour {
            var rgba = [UInt8](repeating: 255, count: n * 4)   // alpha stays 255: opaque
            rgba.withUnsafeMutableBufferPointer { o in
                t.band.withUnsafeBufferPointer { bt in
                    t.grey.withUnsafeBufferPointer { gt in
                        ExposureMaps.palette.withUnsafeBufferPointer { pt in
                            for i in 0..<n {
                                let l = Int(lum[i]), k = Int(bt[l]), p = i * 4
                                if k == 0 {
                                    let g = gt[l]
                                    o[p] = g; o[p + 1] = g; o[p + 2] = g
                                } else {
                                    o[p] = pt[k * 3]; o[p + 1] = pt[k * 3 + 1]; o[p + 2] = pt[k * 3 + 2]
                                }
                            }
                        }
                    }
                }
            }
            c = ExposureMaps.image(rgba, W, H, gray: false)
        }
        return (z, c)
    }

    private static func image(_ bytes: [UInt8], _ W: Int, _ H: Int, gray: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: gray ? 8 : 32, bytesPerRow: gray ? W : W * 4,
                       space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Screenshot scene, values as the copy holds them (255 = 100 IRE).
    private static func fakeScene(_ W: Int, _ H: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: W * H)
        let s = Double(min(W, H))
        for y in 0..<H {
            let v = Double(y) / Double(H)
            for x in 0..<W {
                let u = Double(x) / Double(W)
                var l: Double
                if v < 0.36 {
                    l = 205 + 48 * (1 - v / 0.36)                       // sky: 98 IRE at the top, 80 at the horizon
                } else if v > 0.8 {
                    l = 4 + 30 * (1 - (v - 0.8) / 0.2)                  // ground: 13 IRE down to 2
                } else {
                    l = 125 + 22 * sin(u * 7) - 30 * (v - 0.36)          // wall, mid tones
                }
                // Sun (clipped).
                let sx = (Double(x) - Double(W) * 0.8) / s, sy = (Double(y) - Double(H) * 0.14) / s
                if sx * sx + sy * sy < 0.07 * 0.07 { l = 255 }
                // A shiny window (near white).
                if u > 0.66, u < 0.75, v > 0.42, v < 0.6 { l = 245 }
                // Grey card (18%: 41 IRE).
                if u > 0.1, u < 0.22, v > 0.46, v < 0.7 { l = 105 }
                // A face (skin, about 55 IRE) with a little shading.
                let fx = (Double(x) - Double(W) * 0.48) / (s * 0.12), fy = (Double(y) - Double(H) * 0.56) / (s * 0.17)
                let d = fx * fx + fy * fy
                if d < 1 { l = 143 - 14 * d - 6 * fx }
                // A little noise, as a camera has.
                let h = (x &* 73856093) ^ (y &* 19349663)
                l += Double(h % 5) - 2
                out[y * W + x] = UInt8(max(0, min(255, l)))
            }
        }
        return out
    }
}

// MARK: - over the picture

/// Over the picture: false colour (the whole picture, opaque) and zebras (stripes over the bright
/// parts). From ExposureMaps. Drawn only. Goes under the peaking (CameraScreen).
struct ExposureLayer: View {
    @ObservedObject var aids: PictureAids
    @ObservedObject var maps: ExposureMaps

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let aspect = aids.frameAspect ?? (landscape ? 16.0 / 9 : 9.0 / 16)
            let pic = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: CGRect(origin: .zero, size: geo.size))
            // Frames turned the other way from the screen (a time-lapse keeps them level): not drawn.
            if (aspect > 1) == landscape {
                if maps.falseColour, let img = maps.colourMap {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: pic.width, height: pic.height)
                        .position(x: pic.midX, y: pic.midY)
                }
                if maps.zebra > 0, let m = maps.zebraMask {
                    ZebraStripes()
                        .frame(width: pic.width, height: pic.height)
                        .mask {
                            Image(decorative: m, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .luminanceToAlpha()
                        }
                        .position(x: pic.midX, y: pic.midY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Diagonal black and white stripes (seen on any brightness), drawn at screen sharpness.
struct ZebraStripes: View {
    var body: some View {
        Canvas { ctx, size in
            let period: CGFloat = 10
            var white = Path(), black = Path()
            var x: CGFloat = -size.height
            while x < size.width + period {
                white.move(to: CGPoint(x: x, y: size.height)); white.addLine(to: CGPoint(x: x + size.height, y: 0))
                let x2 = x + period / 2
                black.move(to: CGPoint(x: x2, y: size.height)); black.addLine(to: CGPoint(x: x2 + size.height, y: 0))
                x += period
            }
            ctx.stroke(white, with: .color(.white.opacity(0.9)), lineWidth: 2.5)
            ctx.stroke(black, with: .color(.black.opacity(0.6)), lineWidth: 2.5)
        }
    }
}

/// Under the status pill (iPhone only), in Android's banner style: the false colour key (tap it:
/// false colour off), or "Zebras off with ProRes".
struct ExposureBanner: View {
    @ObservedObject var aids: PictureAids
    @ObservedObject var maps: ExposureMaps

    var body: some View {
        if maps.anyOn, let n = aids.note {
            // "Off with ProRes" -> "Zebras off with ProRes".
            CamBanner {
                Text("\(maps.falseColour ? "False colour" : "Zebras") \(n.prefix(1).lowercased() + n.dropFirst())")
                    .foregroundStyle(Color.dim)
            }
        } else if maps.falseColour {
            FalseColourKey()
                .contentShape(Capsule())
                .onTapGesture { Haptics.tap(); maps.falseColour = false }
        }
    }
}

/// The false colour bands and their IRE.
struct FalseColourKey: View {
    @Environment(\.cineScale) private var s
    var body: some View {
        CamBanner {
            Text("IRE").font(s.font(12)).foregroundStyle(Color.dim)
            ForEach(ExposureMaps.bands.indices, id: \.self) { i in
                let b = ExposureMaps.bands[i]
                HStack(spacing: s(4)) {
                    cineRect(s(2)).fill(b.color).frame(width: s(12), height: s(12))
                    Text(b.label)
                }
            }
        }
        .fixedSize()
    }
}

// MARK: - settings

/// Settings > Exposure: zebras and false colour (Android settings rows: text options, brass mark).
struct ExposureSection: View {
    @ObservedObject var maps: ExposureMaps
    let codec: Codec

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneOpt("Zebras", ExposureMaps.zebraLevels, maps.zebra, spacing: 10, title: { $0 == 0 ? "Off" : "\($0)" }) { maps.zebra = $0 }
            PaneOnOff("False colour", isOn: $maps.falseColour)
            CineNote("Zebras: stripes where the picture is at or over the level (%). 95-100 = about to clip; 70 = a bright face. " +
                     "False colour: purple = black, blue = dark, green = 18% grey, pink = skin, yellow = near white, red = clipped. Tap its key on the screen to turn it off. " +
                     "Log is read as a normal picture would show it." +
                     (codec.isProRes ? " Off with ProRes." : " Not with ProRes."))
        }
    }
}

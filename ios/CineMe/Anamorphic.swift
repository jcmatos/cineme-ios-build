import SwiftUI

// Anamorphic lenses squeeze the picture sideways (along the sensor's long side). The preview is
// shown wider by the squeeze so it looks right; the clip itself is recorded squeezed, as always.
// With "Tag clips for editors" on, the clip also gets a pixel aspect ratio (ClipFinish.swift), so
// editors (and players that honour it) show it wide without any setting. No re-encoding.
//
// The movie output can't do this when recording: its output settings only take the keys from
// supportedOutputSettingsKeys(for:) (codec and compression), not AVVideoPixelAspectRatioKey.

/// Shows the picture (and everything drawn on it: peaking, tracking boxes, guides) wider by the
/// squeeze, fitted on the screen: in landscape it gets wider and lower (letterbox); in portrait
/// taller. Goes on the preview's ZStack in CameraScreen.
struct Desqueeze: ViewModifier {
    @ObservedObject var pro = ProAV.shared
    /// The recorded picture's long side / short side (all CineMe formats are 16:9).
    var videoAspect: CGFloat = 16.0 / 9
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let s = Desqueeze.scales(size, aspect: videoAspect, squeeze: pro.squeeze.factor)
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .scaleEffect(x: s.width, y: s.height)
            .animation(.easeInOut(duration: 0.25), value: pro.squeeze)
    }

    /// x and y scale for a view of [size] showing an [aspect] picture (aspect-fit), so the picture
    /// becomes [squeeze] times wider along its long side and still fits.
    static func scales(_ size: CGSize, aspect v: CGFloat, squeeze: CGFloat) -> CGSize {
        guard squeeze > 1.001, size.width > 0, size.height > 0, v > 0 else { return CGSize(width: 1, height: 1) }
        let landscape = size.width >= size.height
        // "along" = the screen side the picture's long side lies on.
        let A = landscape ? size.width : size.height
        let C = landscape ? size.height : size.width
        // The picture as the preview shows it now (aspect fit).
        let a0 = A / C > v ? C * v : A
        let c0 = A / C > v ? C : A / v
        // The wider picture, fitted.
        let t = v * squeeze
        let a1 = A / C > t ? C * t : A
        let c1 = A / C > t ? C : A / t
        let along = a1 / a0, across = c1 / c0
        return landscape ? CGSize(width: along, height: across) : CGSize(width: across, height: along)
    }
}

/// Screenshot run "anamorphic" only (the simulator has no camera): a test picture as an
/// anamorphic lens would put it on the sensor (round things squeezed to tall ovals). The
/// Desqueeze modifier around it shows them round again, so the shot proves the stretch works.
struct AnamorphicShotPattern: View {
    @ObservedObject var pro = ProAV.shared
    var body: some View {
        if Shot.screen == "anamorphic" {
            GeometryReader { g in
                let landscape = g.size.width >= g.size.height
                let v: CGFloat = 16.0 / 9
                // The 16:9 picture area, aspect fit (as the preview shows it).
                let w = landscape ? min(g.size.width, g.size.height * v) : min(g.size.width, g.size.height / v)
                let h = landscape ? w / v : w * v
                let k = 1 / pro.squeeze.factor   // the lens squeeze
                Canvas { ctx, sz in
                    let sky = Gradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.34), Color(red: 0.72, green: 0.52, blue: 0.36)])
                    ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: sz.height)))
                    // Round lights (bokeh) and a sun: squeezed along the long side.
                    let long = max(sz.width, sz.height)
                    let d = long * 0.11
                    for i in 0..<7 {
                        let p = CGFloat(i) / 6
                        let cx = landscape ? sz.width * (0.1 + 0.8 * p) : sz.width * 0.5 + (i % 2 == 0 ? -1 : 1) * sz.width * 0.22
                        let cy = landscape ? sz.height * (i % 2 == 0 ? 0.34 : 0.62) : sz.height * (0.1 + 0.8 * p)
                        let ow = landscape ? d * k : d, oh = landscape ? d : d * k
                        ctx.fill(Path(ellipseIn: CGRect(x: cx - ow / 2, y: cy - oh / 2, width: ow, height: oh)),
                                 with: .color(Color(hue: 0.08 + 0.08 * Double(p), saturation: 0.6, brightness: 1).opacity(0.75)))
                        ctx.stroke(Path(ellipseIn: CGRect(x: cx - ow / 2, y: cy - oh / 2, width: ow, height: oh)), with: .color(.white.opacity(0.8)), lineWidth: 2)
                    }
                    // A horizon line.
                    var line = Path()
                    if landscape {
                        line.move(to: CGPoint(x: 0, y: sz.height * 0.8)); line.addLine(to: CGPoint(x: sz.width, y: sz.height * 0.8))
                    } else {
                        line.move(to: CGPoint(x: 0, y: sz.height * 0.85)); line.addLine(to: CGPoint(x: sz.width, y: sz.height * 0.85))
                    }
                    ctx.stroke(line, with: .color(.black.opacity(0.6)), lineWidth: 3)
                }
                .frame(width: w, height: h)
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }
}

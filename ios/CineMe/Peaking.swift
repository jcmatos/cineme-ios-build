import AVFoundation
import SwiftUI

/// Over the picture: focus peaking (red marks on the sharp edges, crisp, not smoothed) and, in AF,
/// small green brackets on the sharp areas. From PictureAids (Aids.swift). Drawn only.
struct PeakingLayer: View {
    @ObservedObject var aids: PictureAids
    @ObservedObject var camera: Camera

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let aspect = aids.frameAspect ?? (landscape ? 16.0 / 9 : 9.0 / 16)
            let pic = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: CGRect(origin: .zero, size: geo.size))
            // Frames turned the other way from the screen (a time-lapse keeps them level): not drawn.
            if (aspect > 1) == landscape {
                if aids.peaking, let img = aids.peaks {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: pic.width, height: pic.height)
                        .position(x: pic.midX, y: pic.midY)
                }
                if aids.zones, camera.autoFocus, aids.sharp.contains(true) {
                    ZoneBrackets(sharp: aids.sharp).frame(width: pic.width, height: pic.height).position(x: pic.midX, y: pic.midY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Small corner brackets in each sharp zone (7 x 5), like a camera's wide AF.
struct ZoneBrackets: View {
    @Environment(\.cineScale) private var s
    let sharp: [Bool]
    var body: some View {
        Canvas { ctx, size in
            let zx = PictureAids.zx, zy = PictureAids.zy
            let zw = size.width / CGFloat(zx), zh = size.height / CGFloat(zy)
            let l = min(zw, zh) * 0.18
            var p = Path()
            for (i, on) in sharp.enumerated() where on {
                let x0 = CGFloat(i % zx) * zw + zw * 0.2, y0 = CGFloat(i / zx) * zh + zh * 0.2
                let x1 = x0 + zw * 0.6, y1 = y0 + zh * 0.6
                let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)]
                for (x, y, dx, dy) in corners {
                    p.move(to: CGPoint(x: x + dx * l, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * l))
                }
            }
            ctx.stroke(p, with: .color(Color.focusWide), lineWidth: s(1.5))
        }
    }
}

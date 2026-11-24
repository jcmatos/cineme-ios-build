import AVFoundation
import SwiftUI

// Framing guides over the picture (the Android app's FramingGuides.kt): rule-of-thirds grid and / or
// a golden (Fibonacci) spiral from a chosen corner. Drawn only, so taps go through to the picture.

/// Golden spiral: off, or the corner its wide arc starts from. Kept as "spiral" (Int).
enum SpiralCorner: Int, CaseIterable, Identifiable {
    case off, topLeft, topRight, bottomLeft, bottomRight
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .topLeft: return "↖"
        case .topRight: return "↗"
        case .bottomLeft: return "↙"
        case .bottomRight: return "↘"
        }
    }
}

struct GuidesLayer: View {
    @Environment(\.cineScale) private var s
    @AppStorage("showGrid") private var grid = false
    @AppStorage("spiral") private var spiral = 0

    var body: some View {
        let corner = SpiralCorner(rawValue: spiral) ?? .off
        if grid || corner != .off {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                // All the clip sizes are 16:9.
                let pic = AVMakeRect(aspectRatio: CGSize(width: landscape ? 16 : 9, height: landscape ? 9 : 16),
                                     insideRect: CGRect(origin: .zero, size: geo.size))
                Path { p in
                    if grid {
                        for i in 1...2 {
                            let x = pic.minX + pic.width * CGFloat(i) / 3
                            let y = pic.minY + pic.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: pic.minY)); p.addLine(to: CGPoint(x: x, y: pic.maxY))
                            p.move(to: CGPoint(x: pic.minX, y: y)); p.addLine(to: CGPoint(x: pic.maxX, y: y))
                        }
                    }
                    if corner != .off {
                        let pts = spiralPoints(corner, portrait: !landscape)
                        for (i, q) in pts.enumerated() {
                            let pt = CGPoint(x: pic.minX + q.x * pic.width, y: pic.minY + q.y * pic.height)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                }
                .stroke(Color.guideLine, lineWidth: s(1.2))
            }
            .allowsHitTesting(false)
        }
    }
}

/// The spiral as points in 0..1 of the frame, its wide outer arc starting at [corner]. Built in a
/// golden rectangle (squares cut off left, top, right, bottom in turn, a quarter circle in each),
/// then stretched to the frame, as camera apps do.
func spiralPoints(_ corner: SpiralCorner, portrait: Bool) -> [CGPoint] {
    let phi: CGFloat = 1.618034
    var x: CGFloat = 0, y: CGFloat = 0, w = phi, h: CGFloat = 1
    var out: [CGPoint] = []
    for k in 0..<12 {
        // Square side, the arc's centre and the angle it starts from (each arc turns +90°, y down).
        let s: CGFloat, cx: CGFloat, cy: CGFloat, a0: CGFloat
        switch k % 4 {
        case 0: s = h; cx = x + s; cy = y + s; a0 = 180; x += s; w -= s
        case 1: s = w; cx = x; cy = y + s; a0 = 270; y += s; h -= s
        case 2: s = h; cx = x + w - s; cy = y; a0 = 0; w -= s
        default: s = w; cx = x + w; cy = y + h - s; a0 = 90; h -= s
        }
        for t in 0...15 {
            let a = (a0 + CGFloat(t) * 6) * .pi / 180
            out.append(CGPoint(x: (cx + s * cos(a)) / phi, y: cy + s * sin(a)))
        }
    }
    // Here the wide arc starts bottom left. Portrait: turn it on its side (it then starts top right).
    var pts = portrait ? out.map { CGPoint(x: $0.y, y: $0.x) } : out
    guard let start = pts.first else { return [] }
    let wantRight = corner == .topRight || corner == .bottomRight
    let wantBottom = corner == .bottomLeft || corner == .bottomRight
    if (start.x > 0.5) != wantRight { pts = pts.map { CGPoint(x: 1 - $0.x, y: $0.y) } }
    if (start.y > 0.5) != wantBottom { pts = pts.map { CGPoint(x: $0.x, y: 1 - $0.y) } }
    return pts
}

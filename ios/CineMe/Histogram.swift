import SwiftUI

/// The histogram box, top left (Android: CameraScreen.kt:260, 846). Tap: luma histogram -> RGB
/// parade (three waveforms side by side) -> luma waveform. Red line on the right = blown highlights,
/// brass line on the left = crushed blacks. Off with ProRes (a short note says so).
/// Landscape 160 x 70dp; portrait 124 x 52dp with a 1dp #55504A frame (it sits on the black bar).
/// The camera screen places it (16dp in from the corner; portrait 12, 46).
struct HistogramCorner: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var aids: PictureAids
    let landscape: Bool

    var body: some View {
        if aids.histogram {
            HistogramBox(aids: aids, framed: !landscape)
                .frame(width: s(landscape ? 160 : 124), height: s(landscape ? 70 : 52))
        }
    }
}

struct HistogramBox: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var aids: PictureAids
    var framed = false

    var body: some View {
        ZStack {
            Color.plate
            if let n = aids.note {
                Text(n).font(s.font(12)).foregroundStyle(Color.dim)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.7).padding(s(4))
            } else if let h = aids.hist {
                let scope = aids.scope
                Canvas { ctx, size in HistogramBox.draw(h, scope, &ctx, size) }
            }
        }
        .clipShape(cineRect(s(6)))
        .overlay { if framed { cineRect(s(6)).strokeBorder(Color.histogramFrame, lineWidth: s(1)) } }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            aids.scope = PictureAids.Scope(rawValue: (aids.scope.rawValue + 1) % 3) ?? .histogram
        }
    }

    static func draw(_ h: HistogramData, _ scope: PictureAids.Scope, _ ctx: inout GraphicsContext, _ size: CGSize) {
        switch scope {
        case .histogram:
            let bw = size.width / CGFloat(h.bins.count)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in h.bins.enumerated() {
                p.addLine(to: CGPoint(x: CGFloat(i) * bw + bw / 2, y: size.height - CGFloat(v) * size.height * 0.92))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
            ctx.fill(p, with: .color(Color.ivory.opacity(0.85)))
            if h.clipped > 0.01 {
                ctx.fill(Path(CGRect(x: size.width - 3, y: 0, width: 2, height: size.height)), with: .color(Color.rec))
            }
            if let first = h.bins.first, first > 0.5 {
                ctx.fill(Path(CGRect(x: 1, y: 0, width: 2, height: size.height)), with: .color(Color.brass))
            }
        case .waveform:
            wave(h.luma, Color.ivory, 0, size.width, &ctx, size)
        case .parade:
            let third = size.width / 3
            wave(h.red, Color.paradeR, 0, third - 2, &ctx, size)
            wave(h.green, Color.paradeG, third + 1, third - 2, &ctx, size)
            wave(h.blue, Color.paradeB, 2 * third + 2, third - 2, &ctx, size)
        }
    }

    /// One waveform grid drawn in [width] from [left]: brighter cell = more pixels there.
    private static func wave(_ cells: [Float], _ color: Color, _ left: CGFloat, _ width: CGFloat, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let cols = HistogramData.cols, levels = HistogramData.levels
        guard cells.count == cols * levels else { return }
        let cw = width / CGFloat(cols), ch = size.height / CGFloat(levels)
        // Cells grouped by brightness (8 steps), one fill each: fewer draw calls.
        var paths = [Path](repeating: Path(), count: 8)
        for c in 0..<cols {
            for l in 0..<levels {
                let v = cells[c * levels + l]
                guard v > 0.01 else { continue }
                let k = min(7, Int(v.squareRoot() * 8))
                paths[k].addRect(CGRect(x: left + CGFloat(c) * cw, y: size.height - CGFloat(l + 1) * ch, width: cw + 0.3, height: ch + 0.3))
            }
        }
        for (k, p) in paths.enumerated() where !p.isEmpty {
            ctx.fill(p, with: .color(color.opacity(Double(k + 1) / 8)))
        }
    }
}

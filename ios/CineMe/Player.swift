import AVFoundation
import Combine
import SwiftUI
import UIKit

/// A clip full screen (Android's PlayerActivity PlayerScreen). Plays at once, muted unless the sound is
/// on. Tap = pause / play, drag left / right = scrub (one screen width = the whole clip). In / Out set
/// the part to keep. Gimbal: W / T short = 2 s forward / back, held = fast, record = next clip, double
/// click = previous.
struct ClipPlayer: View {
    let clips: [LibClip]
    let onGrid: (String) -> Void
    let onHelp: () -> Void
    let onClose: () -> Void
    @ObservedObject private var store = ClipStore.shared
    @StateObject private var model = PlayerModel()
    @State private var current: String
    @State private var confirm = false
    @State private var dragFrom: Double? = nil
    @State private var firstClick: Task<Void, Never>? = nil
    /// Where the clip was filmed (lat, lon), for the map key.
    @State private var place: (Double, Double)? = nil
    private let s = CineScale.player

    init(clips: [LibClip], start: String, onGrid: @escaping (String) -> Void, onHelp: @escaping () -> Void = {},
         onClose: @escaping () -> Void) {
        self.clips = clips
        self.onGrid = onGrid
        self.onHelp = onHelp
        self.onClose = onClose
        _current = State(initialValue: start)
    }

    private var index: Int? { clips.firstIndex { $0.name == current } }
    private var clip: LibClip? { index.map { clips[$0] } }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                picture
                // Tap = pause / play, drag = scrub, anywhere off the keys.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { model.toggle() }
                    .gesture(scrub(width: geo.size.width))
                if let c = clip {
                    let m = store.mark(c.name)
                    if model.duration > 0 {
                        timeStrip(m)
                        markKeys(c, m, landscape: landscape)
                    }
                    if landscape { landscapeKeys(c, m) } else { portraitKeys(c, m) }
                } else {
                    VStack(spacing: s(16)) {
                        Text("This clip is gone").font(s.font(15)).foregroundStyle(Color.dim)
                        roundKey(action: { onGrid(current) }) { CineIcon(.grid) }
                    }
                }
                if confirm {
                    CineConfirmDialog("Delete this clip?", "It goes to the bin (kept 30 days). The curved arrow brings it back.",
                                      onYes: { confirm = false; delete() }, onNo: { confirm = false })
                }
                if let msg = store.message {
                    Text(msg).font(s.font(15)).foregroundStyle(Color.ivory)
                        .padding(.horizontal, s(20)).padding(.vertical, s(10))
                        .background(Capsule().fill(Color.toastBack))
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear { load() }
        .onDisappear { model.stop(); firstClick?.cancel() }
        .onChange(of: current) { _, _ in load() }
        .onChange(of: store.sound) { _, on in model.setMuted(!on) }
        .onReceive(LibraryRemote.shared.keys) { key($0) }
        .task(id: current) {
            place = nil
            if let c = clip, !c.fake { place = await ClipPlayer.placeOf(c.url) }
        }
    }

    private var picture: some View {
        ZStack {
            Color.black
            if let c = clip, c.fake {
                LibFakeFrame(hue: c.hue).aspectRatio(16 / 9, contentMode: .fit)
            } else {
                PlayerLayerView(player: model.player)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: layout (PlayerActivity.kt:296-316)

    /// Landscape: all on top. Left: grid, sound, older, newer, bin, counter. Right: star, map, undo, help, X.
    private func landscapeKeys(_ c: LibClip, _ m: ClipMark) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: s(10)) {
                gridKey; soundKey; olderKey; newerKey; binKey(m); counter
                Spacer(minLength: 0)
                starKey(c, m); mapKey(c); undoKey; helpKey; closeKey
            }
            .padding(s(16))
            Spacer(minLength: 0)
        }
    }

    /// Portrait: moving around on top, what to do with the clip at the bottom (70dp up).
    private func portraitKeys(_ c: LibClip, _ m: ClipMark) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: s(10)) {
                gridKey; olderKey; newerKey; counter
                Spacer(minLength: 0)
                closeKey
            }
            .padding(s(14))
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                soundKey; Spacer(minLength: 0); binKey(m); Spacer(minLength: 0); starKey(c, m); Spacer(minLength: 0)
                mapKey(c); Spacer(minLength: 0); undoKey; Spacer(minLength: 0); helpKey
            }
            .padding(.horizontal, s(14))
            .padding(.bottom, s(70))
        }
    }

    /// RoundButton (PlayerActivity.kt:330-336): 56dp Plate, 1dp Edge, 0.35 when disabled.
    private func roundKey<C: View>(enabled: Bool = true, action: @escaping () -> Void, @ViewBuilder _ content: @escaping () -> C) -> some View {
        CineRoundKey(size: 56, enabled: enabled, disabledAlpha: 0.35, action: action, content: content)
    }

    private var gridKey: some View { roundKey(action: { onGrid(current) }) { CineIcon(.grid) } }
    private var closeKey: some View { roundKey(action: onClose) { CineIcon(.cross, size: 20) } }
    private var helpKey: some View { roundKey(action: onHelp) { Text("?").font(s.font(24)).foregroundStyle(Color.ivory) } }
    private var soundKey: some View {
        roundKey(action: { store.sound.toggle() }) { CineIcon(.speaker(muted: !store.sound)) }
    }
    /// Older = on down the list (newest first by default); newer = back up.
    private var olderKey: some View {
        roundKey(enabled: (index ?? clips.count) < clips.count - 1, action: { go(1) }) { CineIcon(.chevron(left: true)) }
    }
    private var newerKey: some View {
        roundKey(enabled: (index ?? 0) > 0, action: { go(-1) }) { CineIcon(.chevron(left: false)) }
    }
    private var undoKey: some View {
        roundKey(enabled: !store.undo.isEmpty, action: { store.undoLast() }) { CineIcon(.undo) }
    }

    private func binKey(_ m: ClipMark) -> some View {
        roundKey(action: {
            if m.star { store.say("Starred: un-star it first") } else { confirm = true }
        }) { CineIcon(.trash) }
    }

    private func starKey(_ c: LibClip, _ m: ClipMark) -> some View {
        roundKey(action: {
            var n = m
            n.star.toggle()
            store.setMark(c.name, n, label: m.star ? "star removed" : "star")
        }) { CineIcon(.star(filled: m.star), color: m.star ? Color.starAmber : Color.ivory) }
    }

    /// Where it was filmed: Apple Maps with a pin (only clips with a location).
    private func mapKey(_ c: LibClip) -> some View {
        roundKey(enabled: place != nil, action: {
            guard let p = place else { return }
            let q = c.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "CineMe"
            if let u = URL(string: "https://maps.apple.com/?ll=\(p.0),\(p.1)&q=\(q)") { UIApplication.shared.open(u) }
        }) { CineIcon(.pin) }
    }

    /// "n / N", counted from the oldest as on Android: Dim 14sp, Plate capsule, padding 12x5.
    @ViewBuilder private var counter: some View {
        if !clips.isEmpty {
            Text("\(clips.count - (index ?? 0)) / \(clips.count)")
                .font(s.font(14)).monospacedDigit().foregroundStyle(Color.dim)
                .padding(.horizontal, s(12)).padding(.vertical, s(5))
                .background(Capsule().fill(Color.plate))
        }
    }

    /// In, Out and (when set) clear. Landscape: stacked at the right; portrait: a row 190dp up.
    @ViewBuilder private func markKeys(_ c: LibClip, _ m: ClipMark, landscape: Bool) -> some View {
        let keys = Group {
            MarkKey(on: m.inS >= 0, action: { setIn(c, m) }) {
                CineIcon(.bracket(isIn: true), color: m.inS >= 0 ? Color.okGreen : Color.ivory)
            }
            MarkKey(on: m.hasRange, action: { setOut(c, m) }) {
                CineIcon(.bracket(isIn: false), color: m.hasRange ? Color.okGreen : Color.ivory)
            }
            if m.inS >= 0 {
                MarkKey(small: true, action: {
                    var n = m
                    n.inS = -1
                    n.outS = -1
                    store.setMark(c.name, n, label: "in / out cleared")
                }) { CineIcon(.cross, size: 16) }
            }
        }
        if landscape {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: s(14)) { keys }.padding(.trailing, s(14))
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: s(24)) { keys }.padding(.bottom, s(190))
            }
        }
    }

    /// Time pill, in / out pill and the thin bar at the bottom (PlayerActivity.kt:508-536).
    private func timeStrip(_ m: ClipMark) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 0) {
                    Text(timeText).font(s.font(14)).monospacedDigit().foregroundStyle(Color.ivory)
                        .padding(.horizontal, s(12)).padding(.vertical, s(4))
                        .background(Capsule().fill(Color.plate))
                    Spacer(minLength: 0)
                    if m.inS >= 0 {
                        Text("\(clipClock(m.inS)) – \(m.outS > m.inS ? clipClock(m.outS) : "…")")
                            .font(s.font(14)).monospacedDigit().foregroundStyle(Color.okGreen)
                            .padding(.horizontal, s(10)).padding(.vertical, s(4))
                            .background(Capsule().fill(Color.plate))
                    }
                }
                .padding(.bottom, s(10))
                PlayerBar(position: model.position, duration: model.duration, mark: m)
            }
            .padding(.horizontal, s(24))
            .padding(.vertical, s(18))
        }
        .allowsHitTesting(false)
    }

    private var timeText: String {
        var t = "\(clipClock(model.position)) / \(clipClock(model.duration))"
        if !model.playing && !model.scrubbing { t += "   paused" }
        if model.shuttleSpeed < 0 { t += "   « \(-model.shuttleSpeed)x" }
        if model.shuttleSpeed > 0 { t += "   \(model.shuttleSpeed)x »" }
        return t
    }

    // MARK: actions

    private func load() {
        guard let c = clip else { return }
        model.load(c, muted: !store.sound, length: store.length(c))
    }

    private func go(_ d: Int) {
        guard let i = index, clips.indices.contains(i + d) else { return }
        current = clips[i + d].name
    }

    private func delete() {
        guard let i = index else { return }
        let c = clips[i]
        let next = i + 1 < clips.count ? clips[i + 1].name : (i > 0 ? clips[i - 1].name : nil)
        store.trash(c)
        // Still there: starred, or the move failed.
        if store.clips.contains(where: { $0.name == c.name }) { return }
        if let n = next { current = n } else { onGrid(c.name) }
    }

    /// In: the frame on screen, and the out point 1 s later (like the PC Video Manager).
    private func setIn(_ c: LibClip, _ m: ClipMark) {
        let now = model.now
        var n = m
        n.inS = now
        n.outS = min(now + 1, model.duration)
        store.setMark(c.name, n, label: "in point")
    }

    /// Out: moves only the end (no in point yet: from the start).
    private func setOut(_ c: LibClip, _ m: ClipMark) {
        let now = model.now
        var n = m
        if m.inS >= 0 && m.inS < now { n.outS = now } else { n.inS = 0; n.outS = now }
        store.setMark(c.name, n, label: "out point")
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                if dragFrom == nil { dragFrom = model.now; model.beginScrub() }
                guard model.duration > 0, width > 0 else { return }
                model.scrub(to: (dragFrom ?? 0) + Double(v.translation.width / width) * model.duration)
            }
            .onEnded { _ in
                dragFrom = nil
                model.endScrub()
            }
    }

    /// Gimbal keys.
    private func key(_ k: LibKey) {
        switch k {
        case .click: click()
        case .forward: model.jump(2)
        case .back: model.jump(-2)
        case .fastForward: model.shuttle(1)
        case .fastBack: model.shuttle(-1)
        case .letGo: model.shuttle(0)
        }
    }

    /// Record: next clip; a second click within 0.4 s: previous instead.
    private func click() {
        if let f = firstClick {
            f.cancel()
            firstClick = nil
            go(-1)
            return
        }
        firstClick = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            firstClick = nil
            go(1)
        }
    }

    /// Where a clip was filmed: its ISO 6709 location ("+55.6761+012.5683/"), or nil.
    static func placeOf(_ url: URL) async -> (Double, Double)? {
        let asset = AVURLAsset(url: url)
        var items: [AVMetadataItem] = []
        if let md = try? await asset.load(.metadata) {
            items = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
        }
        if items.isEmpty, let common = try? await asset.load(.commonMetadata) {
            items = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierLocation)
        }
        guard let item = items.first, let str = (try? await item.load(.stringValue)) ?? nil else { return nil }
        guard let re = try? NSRegularExpression(pattern: "([+-][0-9.]+)([+-][0-9.]+)"),
              let m = re.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let r1 = Range(m.range(at: 1), in: str), let r2 = Range(m.range(at: 2), in: str),
              let lat = Double(str[r1]), let lon = Double(str[r2]) else { return nil }
        return (lat, lon)
    }
}

// MARK: - pieces

/// In / Out / clear (PlayerActivity.kt:563-567): 72dp (clear 48) Plate circle, 2dp green border when set.
private struct MarkKey<Content: View>: View {
    var on = false
    var small = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(on: Bool = false, small: Bool = false, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.on = on
        self.small = small
        self.action = action
        self.content = content
    }

    var body: some View {
        CineRoundKey(size: small ? 48 : 72, border: on ? Color.okGreen : Color.edge, borderWidth: on ? 2 : 1,
                     action: action, content: content)
    }
}

/// The 3dp bar: Edge, Brass up to the position; the in / out part green and thicker, with ticks at
/// both ends (drawn above and below the bar, as Android's).
private struct PlayerBar: View {
    let position: Double
    let duration: Double
    let mark: ClipMark
    private let s = CineScale.player

    var body: some View {
        let h = s(3)
        // Canvas 5h tall: the ticks reach 3h above the bar and 1h below it.
        Canvas { ctx, size in
            let y0 = 3 * h
            let w = size.width
            func bar(_ x0: CGFloat, _ x1: CGFloat, _ thick: CGFloat, _ c: Color) {
                ctx.fill(Path(CGRect(x: x0, y: y0 + h / 2 - thick / 2, width: max(0, x1 - x0), height: thick)), with: .color(c))
            }
            bar(0, w, h, Color.edge)
            guard duration > 0 else { return }
            bar(0, w * CGFloat(min(max(position / duration, 0), 1)), h, Color.brass)
            if mark.inS >= 0 {
                let a = w * CGFloat(mark.inS / duration)
                let b = mark.outS > mark.inS ? w * CGFloat(min(mark.outS, duration) / duration) : a
                bar(a, max(b, a + 1), h * 2.4, Color.okGreen)
                let tick = radioPx(3)
                ctx.fill(Path(CGRect(x: a - tick / 2, y: 0, width: tick, height: 5 * h)), with: .color(Color.okGreen))
                if b > a { ctx.fill(Path(CGRect(x: b - tick / 2, y: 0, width: tick, height: 5 * h)), with: .color(Color.okGreen)) }
            }
        }
        .frame(height: 5 * h)
        .offset(y: h)
    }
}

/// The video picture (AVPlayerLayer). Aspect-fit in the player; the library's tiles fill.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = gravity
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        if v.playerLayer.videoGravity != gravity { v.playerLayer.videoGravity = gravity }
    }
}

// MARK: - the player

/// One AVPlayer for the screen. Seeks one at a time (the newest target wins), so scrubbing shows
/// frames as fast as they decode: keyframes while the finger moves, the exact frame when it rests.
private final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var playing = false
    @Published var scrubbing = false
    /// Gimbal fast forward (+) / back (-): 2x up to 32x.
    @Published var shuttleSpeed = 0

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var fake = false
    private var wasPlaying = false
    private var seekBusy = false
    private var pending: (Double, Bool)?
    private var settle: DispatchWorkItem?
    private var shuttleTimer: Timer?

    init() {
        player.isMuted = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            self?.tick(t)
        }
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        shuttleTimer?.invalidate()
    }

    /// Where the player really is (the bar may lag a little).
    var now: Double {
        let t = player.currentTime().seconds
        return !fake && player.currentItem != nil && t.isFinite ? t : position
    }

    private func tick(_ t: CMTime) {
        guard !fake, let item = player.currentItem else { return }
        let d = item.duration
        if d.isNumeric, d.seconds > 0, abs(d.seconds - duration) > 0.001 { duration = d.seconds }
        if !scrubbing && shuttleSpeed == 0 && t.isNumeric { position = t.seconds }
    }

    func load(_ c: LibClip, muted: Bool, length: Double) {
        shuttleTimer?.invalidate()
        shuttleTimer = nil
        shuttleSpeed = 0
        settle?.cancel()
        pending = nil
        scrubbing = false
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        duration = length
        position = 0
        fake = c.fake
        if c.fake {
            // Screenshot sample: no file, just the controls.
            player.replaceCurrentItem(with: nil)
            position = length * 0.4
            playing = false
            return
        }
        let item = AVPlayerItem(url: c.url)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            self?.playing = false
        }
        player.replaceCurrentItem(with: item)
        setMuted(muted)
        player.play()
        playing = true
    }

    func stop() {
        shuttleTimer?.invalidate()
        shuttleTimer = nil
        settle?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = false
    }

    func setMuted(_ m: Bool) {
        player.isMuted = m
        // Sound on: play it even with the silent switch on.
        if !m {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    func toggle() {
        guard !fake, player.currentItem != nil, shuttleTimer == nil else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            if duration > 0 && position >= duration - 0.05 { seek(0, exact: true); position = 0 }
            player.play()
            playing = true
        }
    }

    // Scrub: finger on the screen.

    func beginScrub() {
        wasPlaying = playing
        player.pause()
        playing = false
        scrubbing = true
    }

    func scrub(to t: Double) {
        position = min(max(t, 0), duration)
        seek(position, exact: false)
        // Finger resting a moment: the exact frame.
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let s = self, s.scrubbing else { return }
            s.seek(s.position, exact: true)
        }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }

    func endScrub() {
        settle?.cancel()
        seek(position, exact: true)
        scrubbing = false
        if wasPlaying && position < duration { player.play(); playing = true }
    }

    /// Gimbal W / T short: this many seconds forward or back.
    func jump(_ s: Double) {
        guard !fake, duration > 0, shuttleTimer == nil else { return }
        position = min(max(now + s, 0), duration)
        seek(position, exact: true)
    }

    /// Gimbal W / T held: 1 = fast forward, -1 = fast back (keyframe to keyframe, faster every second), 0 = let go.
    func shuttle(_ dir: Int) {
        if dir == 0 { stopShuttle(); return }
        guard !fake, duration > 0, shuttleTimer == nil else { return }
        wasPlaying = playing
        player.pause()
        playing = false
        scrubbing = true
        position = now
        let start = Date()
        let speeds = [2, 4, 8, 16, 32]
        shuttleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            let held = Date().timeIntervalSince(start)
            // A lost "let go" must not run forever.
            if held > 30 { s.stopShuttle(); return }
            s.shuttleSpeed = speeds[min(Int(held), speeds.count - 1)] * dir
            s.position = min(max(s.position + Double(s.shuttleSpeed) * 0.05, 0), s.duration)
            s.seek(s.position, exact: false)
        }
    }

    private func stopShuttle() {
        guard let t = shuttleTimer else { return }
        t.invalidate()
        shuttleTimer = nil
        shuttleSpeed = 0
        scrubbing = false
        seek(position, exact: true)
        if wasPlaying && position < duration { player.play(); playing = true }
    }

    /// One seek at a time; while one runs, only the newest target is kept.
    private func seek(_ t: Double, exact: Bool) {
        guard player.currentItem != nil else { return }
        if seekBusy { pending = (t, exact); return }
        seekBusy = true
        let tol: CMTime = exact ? .zero : .positiveInfinity
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            DispatchQueue.main.async { self?.seekDone() }
        }
    }

    private func seekDone() {
        seekBusy = false
        if let p = pending {
            pending = nil
            seek(p.0, exact: p.1)
        }
    }
}

import AVFoundation
import SwiftUI

// Time-lapse (the Android app's Timelapse.kt + CameraController.startTimelapse): one frame every
// few seconds into a clip that plays them at 24, 25 or 30 fps, then it stops by itself (record stops
// it sooner, the clip is kept). AVCaptureMovieFileOutput can't do this and gives no frames, so the
// frames come from the camera's AVCaptureVideoDataOutput and an AVAssetWriter writes them as HEVC.
// The movie output is out of the session while it runs. No sound.

/// A time-lapse running: photos taken, how many in all, seconds between them, the clip's frame rate.
struct TimelapseState: Equatable {
    var shots: Int
    var total: Int
    var interval: Double
    var fps: Int
}

/// The writer side, on Camera.framesQueue only.
final class TimelapseRun {
    let url: URL
    let interval: Double
    let total: Int
    let fps: Int
    var shots = 0
    var firstAt: Double? = nil
    var finishing = false
    var writer: AVAssetWriter? = nil
    var input: AVAssetWriterInput? = nil
    var adaptor: AVAssetWriterInputPixelBufferAdaptor? = nil

    init(url: URL, interval: Double, total: Int, fps: Int) {
        self.url = url; self.interval = interval; self.total = total; self.fps = fps
    }

    /// The file, sized from the first frame. HEVC (H.264 if HEVC can't be had).
    func open(_ pb: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        try? FileManager.default.removeItem(at: url)
        guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h]
        if !wr.canApply(outputSettings: settings, forMediaType: .video) { settings[AVVideoCodecKey] = AVVideoCodecType.h264 }
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        guard wr.canAdd(inp) else { return false }
        wr.add(inp)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: nil)
        wr.metadata = Locator.shared.movieMetadata()   // the place (Locator.swift)
        guard wr.startWriting() else { return false }
        wr.startSession(atSourceTime: .zero)
        writer = wr; input = inp; adaptor = ad
        return true
    }
}

extension Camera {
    /// Starts a time-lapse: [total] frames, one every [interval] seconds, played at [fps]. Main thread.
    func startTimelapse(interval: Double, total: Int, fps: Int) {
        guard !recording, timelapse == nil else { onTimelapseEnd?(); return }
        if codec.isRAW { message = "Time-lapse can't use ProRes RAW: pick another codec in Settings"; onTimelapseEnd?(); return }
        if let p = problem { notRecorded = p; onTimelapseEnd?(); return }
        timelapse = TimelapseState(shots: 0, total: total, interval: interval, fps: fps)
        recording = true
        recordStart = Date()
        let name = "CineMe_TL_" + Camera.stamp.string(from: Date()) + ".mov"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        useFrames(.timelapse, true) { error in
            if let e = error {
                self.timelapse = nil
                self.recording = false
                self.notRecorded = e
                self.onTimelapseEnd?()
                return
            }
            self.framesQueue.async { self.tlRun = TimelapseRun(url: url, interval: interval, total: total, fps: fps) }
        }
    }

    /// Record pressed during a time-lapse: it ends now, the clip so far is kept.
    func stopTimelapse() { framesQueue.async { self.finishTimelapse() } }

    /// A camera frame while a time-lapse runs: kept when the next photo is due. On framesQueue.
    func timelapseFrame(_ pb: CVPixelBuffer, _ time: CMTime) {
        guard let r = tlRun, !r.finishing else { return }
        let now = CMTimeGetSeconds(time)
        let first = r.firstAt ?? now
        r.firstAt = first
        // On the clock from the start, so the gaps don't add up late.
        guard now >= first + Double(r.shots) * r.interval - 0.005 else { return }
        if r.writer == nil, !r.open(pb) {
            publish { self.notRecorded = "Couldn't write the time-lapse file" }
            finishTimelapse()
            return
        }
        guard let inp = r.input, let ad = r.adaptor, inp.isReadyForMoreMediaData else { return }   // the next frame then
        guard ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(r.shots), timescale: CMTimeScale(r.fps))) else {
            let e = r.writer?.error?.localizedDescription ?? "Writing stopped"
            publish { self.notRecorded = e }
            finishTimelapse()
            return
        }
        r.shots += 1
        let s = r.shots, total = r.total
        publish {
            self.timelapse?.shots = s
            self.onTimelapseShot?(s, total)
        }
        if s >= total { finishTimelapse() }
    }

    /// Ends the time-lapse: closes the file, saves it, puts the movie output back. On framesQueue.
    func finishTimelapse() {
        guard let r = tlRun, !r.finishing else { return }
        r.finishing = true
        tlRun = nil
        func ended(_ problem: String?) {
            useFrames(.timelapse, false)
            publish {
                self.recording = false
                self.timelapse = nil
                self.onTimelapseEnd?()
                if let p = problem { self.notRecorded = p }
            }
        }
        guard let w = r.writer, r.shots > 0 else {
            r.writer?.cancelWriting()
            ended("No photos were taken")
            return
        }
        r.input?.markAsFinished()
        // The last photo lasts one frame too.
        w.endSession(atSourceTime: CMTime(value: CMTimeValue(r.shots), timescale: CMTimeScale(r.fps)))
        w.finishWriting {
            if w.status == .completed {
                self.save(r.url)
                ended(nil)
            } else {
                ended(w.error?.localizedDescription ?? "The time-lapse wasn't written")
            }
        }
    }
}

// MARK: - the time-lapse dialog (Timelapse.kt)

/// Seconds between photos, minutes of shooting: the knobs click through these (as on Android).
private let tlIntervals: [Double] = [0.5, 1, 2, 3, 4, 5, 8, 10, 15, 20, 30, 45, 60]
private let tlMinutes: [Int] = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360]
private let tlRates: [Int] = [24, 25, 30]

/// What a time-lapse set like this gives.
struct TimelapsePlan {
    var interval: Double
    var minutes: Int
    var fps: Int
    var shots: Int { max(2, Int((Double(minutes) * 60 / interval).rounded(.up))) }
    var clipSeconds: Double { Double(shots) / Double(fps) }
    /// How many times faster than real life it plays.
    var speedUp: Double { interval * Double(fps) }
}

/// Android's hms(): "1 h 05 min", "9 min 56 s", "10 s".
func tlTime(_ sec: Double) -> String {
    let s = Int(sec.rounded())
    if s >= 3600 { return String(format: "%d h %02d min", s / 3600, s % 3600 / 60) }
    if s >= 60 { return String(format: "%d min %02d s", s / 60, s % 60) }
    return "\(s) s"
}

private func tlSecs(_ v: Double) -> String { v < 1 ? "½ s" : "\(Int(v.rounded())) s" }
private func tlMins(_ v: Int) -> String { v >= 60 && v % 60 == 0 ? "\(v / 60) h" : v >= 60 ? "\(v / 60) h \(v % 60)" : "\(v) min" }

/// The time-lapse popup (stopwatch key), old-radio look: EVERY and FOR knobs, the clip's frame rate,
/// optionally a saved move spread over the whole shoot; the cream card says what comes out.
/// START calls `onStart` then `onClose`; CANCEL or a tap outside calls `onClose`.
struct TimelapseDialog: View {
    @ObservedObject var mover: Mover
    let onStart: (TimelapsePlan, MovePreset?) -> Void
    let onClose: () -> Void
    private let s = CineScale.cam
    @State private var iIdx: Int
    @State private var mIdx: Int
    @State private var fps: Int
    @State private var move: MovePreset?

    init(mover: Mover, onStart: @escaping (TimelapsePlan, MovePreset?) -> Void, onClose: @escaping () -> Void) {
        _mover = ObservedObject(wrappedValue: mover)
        self.onStart = onStart
        self.onClose = onClose
        let d = UserDefaults.standard
        let interval = d.object(forKey: "tlInterval") as? Double ?? 2
        let minutes = d.object(forKey: "tlMinutes") as? Int ?? 10
        let rate = d.object(forKey: "tlFps") as? Int ?? 30
        let savedMove = d.string(forKey: "tlMove") ?? ""
        _iIdx = State(initialValue: tlIntervals.firstIndex { $0 >= interval } ?? 0)
        _mIdx = State(initialValue: tlMinutes.firstIndex { $0 >= minutes } ?? 0)
        _fps = State(initialValue: tlRates.contains(rate) ? rate : 30)
        _move = State(initialValue: mover.store.presets.first { $0.id == savedMove })
    }

    private var plan: TimelapsePlan { TimelapsePlan(interval: tlIntervals[iIdx], minutes: tlMinutes[mIdx], fps: fps) }

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            CineScrim(color: .scrimDark, onTapOutside: onClose) {
                panel(portrait).radioPanel(h: 26, v: 16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The panel centred on the whole screen, as Android's (Timelapse.kt:84), not the safe area.
        .ignoresSafeArea()
        .cineScale(.cam)
    }

    private func panel(_ portrait: Bool) -> some View {
        VStack(spacing: 0) {
            Text("TIME-LAPSE")
                .font(s.font(15, .semibold))
                .tracking(s.tracking(0.3, sp: 15))
                .foregroundStyle(Color.brass)
            Spacer().frame(height: s(8))
            // Portrait: the knobs on one line, what comes out under them.
            if portrait {
                HStack(spacing: s(14)) { controls }
                Spacer().frame(height: s(12))
                result
            } else {
                HStack(spacing: s(18)) { controls; result }
            }
            Spacer().frame(height: s(10))
            // A saved move, spread over the whole shoot: start at the first photo, end at the last.
            Text("MOVE (saved moves only)")
                .font(s.font(11))
                .tracking(s.tracking(0.2, sp: 11))
                .foregroundStyle(Color.brass)
            Spacer().frame(height: s(6))
            ViewThatFits(in: .horizontal) {
                moveKeys
                ScrollView(.horizontal, showsIndicators: false) { moveKeys }
            }
            if move != nil && plan.interval < 2 {
                Text("With a move, 2 s or more between photos, so each small step is done before the next photo.")
                    .font(s.font(12))
                    .foregroundStyle(Color.levelYellow)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, s(6))
            }
            Spacer().frame(height: s(12))
            HStack(alignment: .top, spacing: s(12)) {
                PianoKey("START", wide: true) {
                    let d = UserDefaults.standard
                    d.set(plan.interval, forKey: "tlInterval")
                    d.set(plan.minutes, forKey: "tlMinutes")
                    d.set(plan.fps, forKey: "tlFps")
                    d.set(move?.id ?? "", forKey: "tlMove")
                    onStart(plan, move)
                    onClose()
                }
                PianoKey("CANCEL", action: onClose)
            }
            Text("Record stops it early (the clip is kept). No sound in a time-lapse. Keep the phone plugged in for long ones.")
                .font(s.font(12))
                .foregroundStyle(Color.walnutHint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s(8))
        }
    }

    @ViewBuilder private var controls: some View {
        RadioKnob("EVERY", value: Float(iIdx), lo: 0, hi: Float(tlIntervals.count - 1), step: 1,
                  format: { tlSecs(tlIntervals[min(max(Int($0.rounded()), 0), tlIntervals.count - 1)]) }) { v in
            iIdx = min(max(Int(v.rounded()), 0), tlIntervals.count - 1)
        }
        RadioKnob("FOR", value: Float(mIdx), lo: 0, hi: Float(tlMinutes.count - 1), step: 1,
                  format: { tlMins(tlMinutes[min(max(Int($0.rounded()), 0), tlMinutes.count - 1)]) }) { v in
            mIdx = min(max(Int(v.rounded()), 0), tlMinutes.count - 1)
        }
        VStack(spacing: s(6)) {
            ForEach(tlRates, id: \.self) { r in
                RadioSmallKey("\(r) fps", down: fps == r) { fps = r }
            }
        }
    }

    /// What comes out: the cream card.
    private var result: some View {
        let p = plan
        return VStack(alignment: .leading, spacing: 0) {
            line("Clip", tlTime(p.clipSeconds), big: true)
            line("Shooting", tlTime(Double(p.minutes) * 60))
            line("Photos", "\(p.shots)")
            line("Faster", (p.speedUp >= 10 ? "\(Int(p.speedUp.rounded()))" : String(format: "%.1f", p.speedUp)) + "x")
            line("Size", sizeText(p))
            line("Ends at", Self.clock.string(from: Date().addingTimeInterval(Double(p.minutes) * 60)))
        }
        .padding(.horizontal, s(14))
        .padding(.vertical, s(10))
        .frame(width: s(250), alignment: .leading)
        .background(cineRect(s(10)).fill(Color.dialGlass))
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The clip's size. Android multiplies its bitrate setting; here the frames go through
    /// AVAssetWriter's own HEVC settings, so this is an estimate: about 0.12 bit per pixel a frame.
    private func sizeText(_ p: TimelapsePlan) -> String {
        let res = mover.camera?.resolution ?? .uhd
        let mb = Double(res.width) * Double(res.height) * 0.12 / 8 / 1_000_000 * Double(p.shots)
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : "\(Int(mb.rounded())) MB"
    }

    private func line(_ label: String, _ value: String, big: Bool = false) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(label).font(s.font(13)).foregroundStyle(Color.dialInk.opacity(0.7))
                .frame(width: s(80), alignment: .leading)
            Text(value).font(s.font(big ? 22 : 16, big ? .semibold : .medium)).foregroundStyle(Color.dialInk)
        }
    }

    private var moveKeys: some View {
        HStack(spacing: s(8)) {
            RadioSmallKey("NONE", down: move == nil) { move = nil }
            ForEach(mover.store.presets) { p in
                RadioSmallKey(p.label.replacingOccurrences(of: " in \(p.secs) s", with: ""), down: move == p, wide: true) { move = p }
            }
        }
    }
}

/// Time-lapse small key (Timelapse.kt:161-167): 36dp tall, corner 6, cream (pressed darker), 1dp
/// border, DialInk 13sp w600.
struct RadioSmallKey: View {
    let text: String
    let down: Bool
    var wide = false
    let action: () -> Void
    private let s = CineScale.cam

    init(_ text: String, down: Bool, wide: Bool = false, action: @escaping () -> Void) {
        self.text = text
        self.down = down
        self.wide = wide
        self.action = action
    }

    var body: some View {
        let shape = cineRect(s(6))
        Button(action: action) {
            Text(text)
                .font(s.font(13, .semibold))
                .foregroundStyle(Color.dialInk)
                .lineLimit(1)
                .padding(.horizontal, s(wide ? 12 : 10))
                .frame(height: s(36))
                .background(shape.fill(down ? Color.smallKeyDown : Color.smallKeyUp))
                .overlay(shape.strokeBorder(Color.keyBorder, lineWidth: s(1)))
                .contentShape(shape)
        }
        .buttonStyle(CinePressStyle())
    }
}

/// Old entry point, kept so CameraScreen builds until it shows TimelapseDialog as an overlay itself.
struct TimelapseSheet: View {
    @ObservedObject var mover: Mover
    let onStart: (TimelapsePlan, MovePreset?) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TimelapseDialog(mover: mover, onStart: onStart) { dismiss() }
            .presentationBackground(.clear)
    }
}

/// Running (CameraScreen.kt:377-383): photos, time left, how long the clip is so far. Red 75% capsule,
/// Ivory 15sp, padding 16x6. Android puts it 62dp from the top (96 in portrait).
struct TimelapseBanner: View {
    let t: TimelapseState
    private let s = CineScale.cam
    var body: some View {
        let left = Double(t.total - t.shots) * t.interval
        Text("TIME-LAPSE  \(t.shots) / \(t.total)   \(tlTime(left)) left   clip \(tlTime(Double(t.shots) / Double(t.fps))) of \(tlTime(Double(t.total) / Double(t.fps)))")
            .font(s.font(15))
            .foregroundStyle(Color.ivory)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, s(16))
            .padding(.vertical, s(6))
            .background(Capsule().fill(Color.rec.opacity(0.75)))
    }
}

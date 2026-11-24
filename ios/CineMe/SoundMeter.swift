import AVFoundation
import SwiftUI

// Sound meters: the mic's level, left and right (or one bar when the mic is mono), with a peak hold
// line and a red clip mark. On the camera screen, while idle and while recording.
//
// Where the levels come from:
// 1. An AVCaptureAudioDataOutput in the camera's session, beside the movie output (same audio
//    input). Its sample buffers flow whenever the session runs, recording or not, and the peaks are
//    worked out here from the samples. This also avoids iOS 26.4-26.5, where AVCaptureAudioChannel's
//    averagePowerLevel / peakHoldLevel stayed at -120 (Apple FB22272504, fixed in iOS 27).
// 2. When no buffers come (the output couldn't be added, or was taken out), the movie output's own
//    audio connection: AVCaptureAudioChannel.peakHoldLevel, polled. It may only move while recording.
// The clip's sound comes first: just before a take starts, if the movie output's audio connection
// isn't active while the meter's output is in the session, the meter's output is taken out (and the
// rec log says so). Settings > Sound > Sound meters off takes it out of the session too.

final class SoundMeter: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = SoundMeter()

    /// Settings > Sound.
    @Published var on: Bool = UserDefaults.standard.object(forKey: "soundMeters") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(on, forKey: "soundMeters")
            lock.lock(); wanted = on; lock.unlock()
            camera?.refreshSoundMeter()
            if !on { reading = Reading() }
        }
    }

    /// What the meters show, per channel (1 or 2), dBFS.
    struct Reading: Equatable {
        var level: [Float] = []
        var hold: [Float] = []
        var clip: [Bool] = []
        /// Sound is coming in now.
        var live = false
    }
    @Published private(set) var reading = Reading()

    /// The bottom of the scale, dBFS.
    static let floor: Float = -48
    /// A peak this close to full scale counts as clipped.
    static let clipDb: Float = -0.2

    private let output = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "cineme.sound")
    private let lock = NSLock()
    // Under [lock].
    private var wanted: Bool
    /// Taken out before a take (the clip's sound wasn't active beside it): not added again this run.
    private var blocked = false
    private weak var movie: AVCaptureMovieFileOutput?
    /// Linear peaks (0..1) since the last tick, left and right.
    private var pending: [Float] = [0, 0]
    private var channels = 0
    private var lastBufferAt: TimeInterval = 0
    // Main thread.
    private weak var camera: Camera?
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var holdAt: [TimeInterval] = [0, 0]
    private var clipAt: [TimeInterval] = [-100, -100]

    override init() {
        wanted = UserDefaults.standard.object(forKey: "soundMeters") as? Bool ?? true
        super.init()
    }

    // MARK: - main thread

    /// The camera screen is up: the meters tick 30 times a second (not in screenshot runs).
    func attach(_ c: Camera) {
        camera = c
        guard Shot.screen == nil, timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Screenshot runs: a voice, a little louder on the left, which just clipped.
    func fakeForShots() {
        reading = Reading(level: [-14, -19], hold: [-6, -9], clip: [true, false], live: true)
    }

    @objc private func tick() {
        guard on else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(lastTick == 0 ? 1.0 / 30 : min(0.2, now - lastTick))
        lastTick = now
        lock.lock()
        let fresh = channels > 0 && now - lastBufferAt < 0.5
        let p = pending
        pending = [0, 0]
        let n = channels
        let mv = movie
        lock.unlock()

        var peaks: [Float] = []
        if fresh {
            peaks = (0..<n).map { SoundMeter.db(p[$0]) }
        } else if let c = mv?.connection(with: .audio) {
            // Fallback: the clip's own sound connection (silent = -120, also on iOS 26.4-26.5).
            let levels = c.audioChannels.prefix(2).map { $0.peakHoldLevel }
            if levels.contains(where: { $0 > -119 }) { peaks = levels }
        }

        var r = reading
        let live = !peaks.isEmpty
        let count = live ? peaks.count : r.level.count
        if r.level.count != count {
            r = Reading(level: Array(repeating: SoundMeter.floor, count: count), hold: Array(repeating: SoundMeter.floor, count: count),
                        clip: Array(repeating: false, count: count), live: live)
        }
        for i in 0..<count {
            let target = live ? max(SoundMeter.floor, min(0, peaks[i])) : SoundMeter.floor
            // Up at once, down 24 dB a second.
            r.level[i] = target >= r.level[i] ? target : max(target, r.level[i] - 24 * dt)
            // The hold line stays 1.5 s, then falls.
            if target >= r.hold[i] {
                r.hold[i] = target; holdAt[i] = now
            } else if now - holdAt[i] > 1.5 {
                r.hold[i] = max(r.level[i], r.hold[i] - 20 * dt)
            }
            if live && peaks[i] >= SoundMeter.clipDb { clipAt[i] = now }
            r.clip[i] = now - clipAt[i] < 3
        }
        r.live = live
        if r != reading { reading = r }
    }

    private static func db(_ x: Float) -> Float { x > 0 ? 20 * log10f(x) : -120 }

    // MARK: - camera's queue (Camera.swift calls these)

    /// Video mode, inside a session configuration: the meter's output in (setting on) or out.
    func install(in session: AVCaptureSession, movie: AVCaptureMovieFileOutput) {
        lock.lock()
        let want = wanted && !blocked
        self.movie = movie
        lock.unlock()
        let inSession = session.outputs.contains(output)
        if want, !inSession {
            guard session.canAddOutput(output) else { RecLog.w("sound meter: can't add its output"); return }
            output.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutput(output)
        } else if !want, inSession {
            session.removeOutput(output)
        }
    }

    /// Photo mode, inside a session configuration: no meters.
    func remove(from session: AVCaptureSession) {
        if session.outputs.contains(output) { session.removeOutput(output) }
        lock.lock(); movie = nil; lock.unlock()
    }

    /// Just before movie.startRecording: the clip's sound first. If the movie output's audio
    /// connection isn't active beside the meter's output, the meter's output goes (this run).
    func checkBeforeRecording(session: AVCaptureSession, movie: AVCaptureMovieFileOutput) {
        guard session.outputs.contains(output), let c = movie.connection(with: .audio) else { return }
        if c.isEnabled && c.isActive { return }
        RecLog.w("sound meter off: the clip's sound connection wasn't active beside it (enabled \(c.isEnabled), active \(c.isActive))")
        lock.lock(); blocked = true; lock.unlock()
        session.beginConfiguration()
        session.removeOutput(output)
        session.commitConfiguration()
    }

    // MARK: - samples (audioQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return }
        let chans = Int(asbd.mChannelsPerFrame)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let split = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard chans > 0, isFloat ? bits == 32 : (bits == 16 || bits == 32) else { return }

        let buffers = split ? chans : 1
        let list = AudioBufferList.allocate(maximumBuffers: buffers)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: buffers),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { return }

        // Sample peaks, left (0) and right (1); a third channel and up count as right.
        var peak: [Float] = [0, 0]
        for (k, buf) in list.enumerated() {
            guard let data = buf.mData else { continue }
            let per = max(1, Int(buf.mNumberChannels))
            let count = Int(buf.mDataByteSize) / (bits / 8)
            for i in 0..<count {
                let ch = min(1, split ? k : i % per)
                let v: Float
                if isFloat {
                    v = abs(data.assumingMemoryBound(to: Float.self)[i])
                } else if bits == 16 {
                    v = abs(Float(data.assumingMemoryBound(to: Int16.self)[i])) / 32768
                } else {
                    v = abs(Float(data.assumingMemoryBound(to: Int32.self)[i])) / 2_147_483_648
                }
                if v > peak[ch] { peak[ch] = v }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        pending[0] = max(pending[0], peak[0])
        pending[1] = max(pending[1], peak[1])
        channels = min(2, chans)
        lastBufferAt = now
        lock.unlock()
    }
}

// MARK: - on the camera screen

/// Under the histogram (or in its place when it's off), as wide as it: 160dp landscape, 124dp
/// portrait. The camera screen places it. Not in photo mode. (iPhone only: Android has no meters.)
struct MeterCorner: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var meter: SoundMeter
    @ObservedObject var aids: PictureAids
    @ObservedObject var photo: PhotoTaker
    let camera: Camera
    let landscape: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0).onAppear { meter.attach(camera) }
            // Only while sound comes in (or to say the mic isn't allowed): with nothing to show, the
            // corner stays as Android's, the histogram alone.
            let micOff = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
            if meter.on && !photo.on && (meter.reading.live || micOff) {
                MeterBox(meter: meter, framed: !landscape)
                    .frame(width: s(landscape ? 160 : 124))
            }
        }
    }
}

/// The bars: -48 to 0 dB; ivory, brass from -18, red from -6; thin line = peak hold; the small
/// square at the right end turns red when that side clipped (3 s). A Plate box like the histogram's.
struct MeterBox: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var meter: SoundMeter
    var framed = false

    var body: some View {
        let r = meter.reading
        let n = max(1, min(2, r.level.count))
        let micOff = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        ZStack {
            Color.plate
            if micOff {
                Text("Mic not allowed").font(s.font(12)).foregroundStyle(Color.dim)
            } else {
                Canvas { ctx, size in MeterBox.draw(r, n, &ctx, size) }
                    .padding(.horizontal, s(6)).padding(.vertical, s(5))
            }
        }
        .frame(height: s(n == 2 ? 30 : 20))
        .clipShape(cineRect(s(6)))
        .overlay { if framed { cineRect(s(6)).strokeBorder(Color.histogramFrame, lineWidth: s(1)) } }
        .allowsHitTesting(false)
    }

    static func draw(_ r: SoundMeter.Reading, _ n: Int, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let gap: CGFloat = 3
        let barH = (size.height - gap * CGFloat(n - 1)) / CGFloat(n)
        let labelW: CGFloat = n == 2 ? 9 : 0
        let clipW: CGFloat = 6
        let x0 = labelW, x1 = size.width - clipW - 2
        let floor = SoundMeter.floor
        func x(_ db: Float) -> CGFloat { x0 + (x1 - x0) * CGFloat((max(floor, min(0, db)) - floor) / -floor) }
        let zones: [(Float, Float, Color)] = [(floor, -18, Color.ivory.opacity(0.85)), (-18, -6, Color.brass), (-6, 0, Color.rec)]
        for i in 0..<n {
            let y = CGFloat(i) * (barH + gap)
            if n == 2 {
                ctx.draw(Text(i == 0 ? "L" : "R").font(.jost(8, .semibold)).foregroundStyle(Color.dim),
                         at: CGPoint(x: labelW / 2 - 1, y: y + barH / 2))
            }
            // Track, then the level in its zone colours.
            ctx.fill(Path(CGRect(x: x0, y: y, width: x1 - x0, height: barH)), with: .color(.white.opacity(0.1)))
            let level = i < r.level.count ? r.level[i] : floor
            for (from, to, color) in zones where level > from {
                let a = x(from), b = x(min(level, to))
                ctx.fill(Path(CGRect(x: a, y: y, width: max(0, b - a), height: barH)), with: .color(color))
            }
            // Scale marks at -18 and -6.
            for m: Float in [-18, -6] {
                ctx.fill(Path(CGRect(x: x(m) - 0.5, y: y, width: 1, height: barH)), with: .color(.black.opacity(0.45)))
            }
            // Peak hold.
            if i < r.hold.count, r.hold[i] > floor + 0.5 {
                let h = r.hold[i]
                let color = h >= -6 ? Color.rec : h >= -18 ? Color.brass : Color.ivory
                ctx.fill(Path(CGRect(x: x(h) - 1, y: y, width: 2, height: barH)), with: .color(color))
            }
            // Clip mark.
            let clipped = i < r.clip.count && r.clip[i]
            ctx.fill(Path(roundedRect: CGRect(x: size.width - clipW, y: y, width: clipW, height: barH), cornerRadius: 1.5),
                     with: .color(clipped ? Color.rec : .white.opacity(0.15)))
        }
    }
}

// MARK: - settings

/// Settings > Sound (Android settings rows: text options, brass mark on the chosen one).
struct SoundSection: View {
    @ObservedObject var meter: SoundMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneOnOff("Sound meters", isOn: $meter.on)
            CineNote("The mic's level, left and right, from -48 to 0 dB, also before you record. Aim for brass, not red. Thin line = the loudest a moment ago. A red square at the end = too loud (clipped): move the mic back or lower the sound.")
        }
    }
}

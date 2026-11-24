import AVFoundation
import SwiftUI

// Time-of-day timecode, as other cameras and sound recorders use it: hours, minutes, seconds and
// frames since midnight (phone's clock and time zone). Two cameras with the right time line up in
// the editor by timecode (to the clock's accuracy: the iPhone's clock is set over the network).
//
// AVCaptureMovieFileOutput can't write a timecode track itself (no API for it, up to the iOS 27
// SDK). iOS 26's AVCaptureTimecodeGenerator only makes timecodes and sample buffers for apps
// that write their own files with AVAssetWriter. So the track is added after recording, in
// place, without re-encoding (ClipFinish.swift).

enum TimeOfDay {
    /// The timecode rate for a frame rate: the frame rate up to 60; above, halved until <= 60
    /// (100 -> 50, 120 -> 60, 240 -> 60), as editors expect a normal timecode rate.
    static func rate(_ fps: Int) -> Int {
        var r = max(1, fps)
        while r > 60 { r /= 2 }
        return r
    }

    /// Frames since midnight at [rate] for this moment (local time).
    static func frames(at date: Date, rate: Int) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let secs = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
        return Int((secs * Double(rate)).rounded(.down)) % (86_400 * rate)
    }

    /// "14:32:08:12"
    static func text(frames: Int, rate: Int) -> String {
        let r = max(1, rate)
        let f = frames % r, s = frames / r
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f)
    }

    static func text(at date: Date, fps: Int) -> String {
        let r = rate(fps)
        return text(frames: frames(at: date, rate: r), rate: r)
    }
}

/// When the clip's first frame was taken, as a wall-clock time.
enum ClipClock {
    /// [pts] is on the session's clock (AVCaptureSession.synchronizationClock, the host time clock).
    /// Falls back to now if the time looks wrong.
    static func wallTime(of pts: CMTime, clock: CMClock?) -> Date {
        let now = Date()
        guard pts.isValid else { return now }
        let hostNow = CMClockGetTime(clock ?? CMClockGetHostTimeClock())
        let ago = CMTimeGetSeconds(CMTimeSubtract(hostNow, pts))
        guard ago.isFinite, ago >= 0, ago < 10 else { return now }
        return now.addingTimeInterval(-ago)
    }
}

/// In the status pill (iPhone only): the running timecode ("TC" Dim 12sp + 14sp digits) when Timecode
/// is on, and the anamorphic squeeze in Brass (as Android shows a recorded filter's name).
struct ProBadges: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var pro = ProAV.shared
    let fps: Int
    var body: some View {
        HStack(spacing: s(14)) {
            if pro.timecode {
                if Shot.screen == "timecode" {
                    tc("14:32:08:12")
                } else {
                    // Up to 30 updates a second is enough to read it.
                    TimelineView(.periodic(from: .now, by: 1.0 / Double(min(TimeOfDay.rate(fps), 30)))) { t in
                        tc(TimeOfDay.text(at: t.date, fps: fps))
                    }
                }
            }
            if pro.squeeze != .off {
                Text("ANA \(pro.squeeze.rawValue)").font(s.font(14)).tracking(s.tracking(0.03, sp: 14))
                    .foregroundStyle(Color.brass).lineLimit(1).fixedSize()
            }
        }
    }

    private func tc(_ v: String) -> some View {
        HStack(spacing: s(5)) {
            Text("TC").font(s.font(12)).foregroundStyle(Color.dim)
            Text(v).font(s.font(14)).monospacedDigit().foregroundStyle(Color.ivory)
        }
        .lineLimit(1).fixedSize()
    }
}

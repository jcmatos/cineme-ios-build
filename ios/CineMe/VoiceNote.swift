import AVFoundation
import SwiftUI

/// Voice notes about the app itself (a bug, an idea), as on Android. Saved as
/// CineMe Notes/CineMe-note-<yyyyMMdd-HHmmss>.m4a in the app's Documents, so they show in
/// Files > On My iPhone > CineMe > CineMe Notes (and in Finder when the iPhone is plugged in).
/// Not while a clip records: the clip has the mic then.
final class VoiceNote {
    struct Item: Identifiable {
        let url: URL
        let seconds: Double
        var id: String { url.lastPathComponent }
        /// CineMe-note-20261014-114610.m4a -> 14 Oct   11:46
        var label: String {
            let d = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "CineMe-note-", with: "")
            guard let date = VoiceNote.stamp.date(from: d) else { return d }
            return VoiceNote.shown.string(from: date)
        }
    }

    static let folderName = "CineMe Notes"
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName, isDirectory: true)
    }

    private var recorder: AVAudioRecorder?
    var recording: Bool { recorder != nil }

    /// False if the mic isn't allowed or can't start.
    func start() -> Bool {
        if recorder != nil { return true }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        let s = AVAudioSession.sharedInstance()
        // The camera's sound has the session set up for recording already: leave it as it is
        // (changing it would cut the camera's sound). Only when nothing records yet, set it up.
        if s.category != .playAndRecord && s.category != .record {
            do {
                try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try s.setActive(true)
            } catch { return false }
        }
        try? FileManager.default.createDirectory(at: VoiceNote.folder, withIntermediateDirectories: true)
        let url = VoiceNote.folder.appendingPathComponent("CineMe-note-" + VoiceNote.stamp.string(from: Date()) + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.prepareToRecord(), r.record() else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        recorder = r
        return true
    }

    /// Stops and keeps the note. True if it was saved.
    /// Never deactivates the audio session: the camera's sound uses it too.
    func stop() -> Bool {
        guard let r = recorder else { return false }
        recorder = nil
        let long = r.currentTime > 0.3
        r.stop()
        if !long { r.deleteRecording() }
        return long && FileManager.default.fileExists(atPath: r.url.path)
    }

    /// Stops and throws the note away.
    func discard() {
        guard let r = recorder else { return }
        recorder = nil
        r.stop()
        r.deleteRecording()
    }

    /// The notes on the phone, newest first.
    static func list() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { Item(url: $0, seconds: (try? AVAudioPlayer(contentsOf: $0))?.duration ?? 0) }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static let shown: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM   HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

/// The voice note panel, over the camera (Android's VoiceNoteDialog): Record / Stop (saves it and
/// closes, back to filming). X while recording asks to throw the note away; X otherwise closes.
struct VoiceNoteView: View {
    @ObservedObject var camera: Camera
    let onClose: () -> Void

    @State private var note = VoiceNote()
    @State private var on = false
    @State private var started = Date()
    @State private var reject = false
    @State private var notes: [VoiceNote.Item] = []

    @Environment(\.cineScale) private var s

    var body: some View {
        ZStack {
            CineScrim {
                CineSheetPanel {
                    Text("Voice note").font(s.font(24, .medium))
                    Spacer().frame(height: s(6))
                    Text(on ? "Recording…" : "A bug or an idea for CineMe").font(s.font(14)).foregroundStyle(Color.dim)
                    Spacer().frame(height: s(20))
                    if on {
                        TimelineView(.periodic(from: started, by: 0.5)) { t in
                            let sec = max(0, Int(t.date.timeIntervalSince(started)))
                            Text(String(format: "%02d:%02d", sec / 60, sec % 60))
                                .font(s.font(30, .medium)).monospacedDigit()
                        }
                        Spacer().frame(height: s(16))
                    }
                    HStack(spacing: s(28)) {
                        CineYesButton(width: 170, action: recordTapped) {
                            HStack(spacing: s(12)) {
                                if on {
                                    cineRect(s(3)).fill(Color.white).frame(width: s(18), height: s(18))
                                } else {
                                    Circle().fill(Color.white).frame(width: s(20), height: s(20))
                                }
                                Text(on ? "Stop" : "Record").font(s.font(24, .semibold))
                            }
                        }
                        CineCloseKey { if on { reject = true } else { onClose() } }
                    }
                    if !on { list.padding(.top, s(20)) }
                }
            }
            // Keeps recording while asking; only Yes throws the note away.
            if reject {
                CineConfirmDialog("Reject this note?", "It is thrown away, not saved.", onYes: {
                    reject = false
                    on = false
                    note.discard()
                    camera.message = "Note rejected"
                    onClose()
                }, onNo: { reject = false })
            }
        }
        .onAppear { refresh() }
        .onDisappear { if note.recording { _ = note.stop() } }
        // The record button (gimbal, remote) started a clip: the clip gets the mic, the note is kept.
        .onChange(of: camera.recording) { _, rec in if rec && on { stop() } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Text(notes.isEmpty ? "No notes on the phone" : "On the phone: \(notes.count)")
                .font(s.font(14)).foregroundStyle(Color.dim)
            ForEach(notes.prefix(6)) { n in
                let sec = Int(n.seconds.rounded())
                Text("\(n.label)    \(sec / 60):\(String(format: "%02d", sec % 60))").font(s.font(15)).padding(.top, s(4))
            }
            if notes.count > 6 {
                Text("and \(notes.count - 6) more").font(s.font(14)).foregroundStyle(Color.dim).padding(.top, s(4))
            }
            if !notes.isEmpty, Shot.screen == nil {
                ShareLink(items: notes.map { $0.url }) {
                    Text("Send notes").font(s.font(15)).foregroundStyle(Color.ivory)
                        .padding(.horizontal, s(13)).padding(.vertical, s(7))
                        .plateCapsule(border: Color.edge)
                }
                .padding(.top, s(10))
            }
            Text("Also in Files > On My iPhone > CineMe > CineMe Notes")
                .font(s.font(12)).foregroundStyle(Color.dim).padding(.top, s(8))
        }
    }

    private func recordTapped() {
        if on { stop(); return }
        if camera.recording { camera.message = "Not while recording"; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { MainActor.assumeIsolated { if ok { begin() } } }
            }
        case .authorized:
            begin()
        default:
            camera.message = "Allow the microphone in Settings > CineMe"
        }
    }

    private func begin() {
        if note.start() {
            on = true
            started = Date()
        } else {
            camera.message = "Microphone not available"
        }
    }

    private func stop() {
        guard on else { return }
        on = false
        camera.message = note.stop() ? "Note saved" : "Note not saved"
        // Back to filming straight away.
        onClose()
    }

    private func refresh() {
        if Shot.screen == "note" {
            let tmp = FileManager.default.temporaryDirectory
            notes = [("20261121-114610", 32.0), ("20261120-093002", 75.0), ("20261118-171544", 9.0)].map {
                VoiceNote.Item(url: tmp.appendingPathComponent("CineMe-note-\($0.0).m4a"), seconds: $0.1)
            }
            return
        }
        notes = VoiceNote.list()
    }
}

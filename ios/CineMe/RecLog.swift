import Foundation
import os

/// A log of every take (start, file, why it failed) and of crashes the app can catch, kept on the
/// phone in Documents/rec-log.txt, so it shows in Files > On My iPhone > CineMe (and in Finder with
/// the iPhone plugged in). The system log only keeps a short time, so without this a bad day can't
/// be looked at afterwards. Port of the Android RecLog.kt. Callable from any thread.
enum RecLog {
    private static let maxBytes: UInt64 = 2_000_000
    private static let queue = DispatchQueue(label: "cineme.reclog")
    private static let logger = Logger(subsystem: "ca.channel13.cineme", category: "rec")
    private static var started = false
    private static var previousHandler: NSUncaughtExceptionHandler? = nil

    static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("rec-log.txt")
    }
    static var oldFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("rec-log.old.txt")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Once at launch: "app started", and Objective-C exceptions (what AVFoundation throws when a
    /// setting is wrong) go into the log before the app ends. Swift crashes can't be caught.
    static func start() {
        let first: Bool = queue.sync {
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { e in
            let stack = e.callStackSymbols.prefix(30).joined(separator: "\n")
            RecLog.writeNow("CRASH \(e.name.rawValue): \(e.reason ?? "")\n\(stack)")
            RecLog.previousHandler?(e)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        w("app started (iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion))")
    }

    /// One line in the log (and in the system log).
    static func w(_ msg: String) {
        logger.info("\(msg, privacy: .public)")
        let at = Date()
        queue.async { append("\(time.string(from: at)) \(msg)\n") }
    }

    /// Straight away, on the calling thread (the crash handler: the queue may never run again).
    private static func writeNow(_ msg: String) {
        append("\(time.string(from: Date())) \(msg)\n")
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        let f = file
        if let size = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? UInt64, size > maxBytes {
            try? fm.removeItem(at: oldFile)
            try? fm.moveItem(at: f, to: oldFile)
        }
        guard let data = line.data(using: .utf8) else { return }
        if !fm.fileExists(atPath: f.path) {
            fm.createFile(atPath: f.path, contents: data)
            return
        }
        guard let h = try? FileHandle(forWritingTo: f) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }
}

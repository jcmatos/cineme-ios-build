import AVFoundation
import BackgroundTasks
import ImageIO
import Network
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Backup to cineme.studiowebworks.com (server/api.php in the repo), the Android Backup.kt on the
// iPhone: each clip and photo becomes a small copy (540p H.264 / 1600 px JPEG) plus a thumbnail and
// is uploaded. The site only MARKS items for deletion; the phone fetches the marked names and asks
// twice before deleting anything.
//
// iPhone differences: the upload itself goes through a background URLSession, so a started upload
// finishes with CineMe in the background or suspended. Converting needs the app running: while it is
// open (every 15 min, 1 min after a take, Sync now), a short grace time after leaving it, and a
// BGProcessingTask that iOS runs when it likes (often at night on the charger). The video copy is
// AVAssetExportSession's 960x540 H.264 preset (HDR comes out SDR), not Android's 480p at 1.2 Mbit/s.

/// A CineMe clip or photo (or the iPhone camera's) on the phone, as the backup sees it.
struct LocalItem: Identifiable, Equatable {
    enum Source: Equatable {
        case file(URL)          // in CineMe's Documents
        case asset(String)      // in Photos (local identifier)
    }
    let source: Source
    let name: String
    let video: Bool
    let taken: Date
    var durationMs: Int64
    var size: Int64
    /// Screenshot runs: a made-up tile.
    var hue: Double? = nil
    var id: String { name }
}

enum BackupError: LocalizedError {
    case http(Int, String)
    case cantConvert(String)
    case gone
    case paused

    var errorDescription: String? {
        switch self {
        case .http(let c, let body): return "HTTP \(c) \(body)"
        case .cantConvert(let why): return why
        case .gone: return "not on the phone any more"
        case .paused: return "paused"
        }
    }
}

/// The site, the login and the settings. Usable from any thread.
enum BackupAPI {
    static let api = "https://cineme.studiowebworks.com/api.php"
    /// The same login as the Android app (backup/Backup.kt, in the repo): the whole site sits behind
    /// nginx basic auth.
    static let auth = "Basic " + Data("__BACKUP_LOGIN__".utf8).base64EncodedString()
    static let photoPx = 1600
    /// An item that failed this often is skipped (a broken file must not block the rest).
    static let maxFails = 3
    /// The BGProcessingTask (also in Info.plist BGTaskSchedulerPermittedIdentifiers).
    static let taskID = "ca.channel13.cineme.backup"

    // Settings, same names as on Android.
    static let autoKey = "autoUpload2"
    static let cameraKey = "backupCamera"
    static let mobileKey = "uploadMobile"
    static let fromKey = "backupFrom"
    static var autoUpload: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    static var phoneCamera: Bool { UserDefaults.standard.object(forKey: cameraKey) as? Bool ?? true }
    static var mobile: Bool { UserDefaults.standard.bool(forKey: mobileKey) }
    /// Nothing taken before this is uploaded (default Friday 9 Oct 2026, 00:00 here, as on Android).
    static var from: Date {
        if let ms = UserDefaults.standard.object(forKey: fromKey) as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        return Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9)) ?? .distantPast
    }

    static func url(_ action: String) -> URL { URL(string: "\(api)?a=\(action)")! }

    /// GET, or a form POST when [form] is given. Small requests only (the uploads use BackupUploader).
    static func request(_ action: String, form: String? = nil) async throws -> Data {
        var r = URLRequest(url: url(action), timeoutInterval: 60)
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        r.allowsCellularAccess = mobile
        if let f = form {
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(f.utf8)
        }
        return try await send(r)
    }

    /// A multipart POST with fields only (?a=sizes).
    static func fieldsPost(_ action: String, _ fields: [(String, String)]) async throws -> Data {
        let b = "cineme" + String(UInt64(Date().timeIntervalSince1970 * 1e6))
        var body = Data()
        for (k, v) in fields { body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8)) }
        body.append(Data("--\(b)--\r\n".utf8))
        var r = URLRequest(url: url(action), timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        r.allowsCellularAccess = mobile
        r.httpBody = body
        return try await send(r)
    }

    private static func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BackupError.http(code, String(decoding: data.prefix(80), as: UTF8.self)) }
        return data
    }

    /// The whole multipart body as a file (a background upload must come from a file).
    static func writeBody(to url: URL, boundary b: String, fields: [(String, String)], files: [(String, URL, String)]) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        fm.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        for (k, v) in fields {
            try h.write(contentsOf: Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        for (k, f, mime) in files {
            try h.write(contentsOf: Data("--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"; filename=\"\(f.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            let r = try FileHandle(forReadingFrom: f)
            defer { try? r.close() }
            while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty { try h.write(contentsOf: chunk) }
            try h.write(contentsOf: Data("\r\n".utf8))
        }
        try h.write(contentsOf: Data("--\(b)--\r\n".utf8))
    }

    /// No network is not the clip's fault: these don't count towards skipping it.
    static func isNetwork(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        let network: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut,
                                        .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive]
        return network.contains(u.code)
    }

    static func describe(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }

    /// Only plain file names reach the site (it accepts [A-Za-z0-9._-]).
    static func cleanName(_ n: String) -> String {
        var s = String(n.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") ? $0 : "_" })
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(120))
    }

    // MARK: copies and thumbnails

    /// A JPEG of at most [maxPx] on the long side, upright, from a HEIC / JPEG / DNG file.
    static func jpeg(from src: URL, maxPx: Int, to out: URL, quality: Double) throws {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw BackupError.cantConvert("can't read the photo") }
        let o: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { throw BackupError.cantConvert("can't decode the photo") }
        try writeJPEG(img, to: out, quality: quality)
    }

    static func writeJPEG(_ img: CGImage, to out: URL, quality: Double) throws {
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BackupError.cantConvert("can't write a JPEG")
        }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw BackupError.cantConvert("can't write a JPEG") }
    }

    /// A still from a video, at most 480x270.
    static func videoThumb(_ asset: AVAsset, to out: URL) async throws {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 480, height: 270)
        let img = try await g.image(at: .zero).image
        try writeJPEG(img, to: out, quality: 0.75)
    }

    static func asset(_ id: String) throws -> PHAsset {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw BackupError.gone }
        return a
    }

    /// A picture from Photos, as a JPEG file.
    static func assetJPEG(_ id: String, size: CGSize, fill: Bool, to out: URL, quality: CGFloat) async throws {
        let img = try await assetImage(id, size: size, fill: fill)
        guard let d = img.jpegData(compressionQuality: quality) else { throw BackupError.cantConvert("can't write a JPEG") }
        try d.write(to: out)
    }

    static func assetImage(_ id: String, size: CGSize, fill: Bool) async throws -> UIImage {
        let a = try asset(id)
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .exact
        o.isNetworkAccessAllowed = true
        final class Once { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UIImage, Error>) in
            PHImageManager.default().requestImage(for: a, targetSize: size, contentMode: fill ? .aspectFill : .aspectFit, options: o) { img, info in
                if once.done || (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                once.done = true
                if let i = img { c.resume(returning: i) }
                else { c.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? BackupError.cantConvert("Photos gave no picture")) }
            }
        }
    }

    static func assetVideo(_ id: String) async throws -> AVAsset {
        let a = try asset(id)
        let o = PHVideoRequestOptions()
        o.isNetworkAccessAllowed = true
        o.deliveryMode = .highQualityFormat
        o.version = .current
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<AVAsset, Error>) in
            PHImageManager.default().requestAVAsset(forVideo: a, options: o) { av, _, info in
                if let av = av { c.resume(returning: av) }
                else { c.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? BackupError.cantConvert("Photos gave no video")) }
            }
        }
    }

    /// Can CineMe read the Photos library (for "Phone camera too")?
    static var photosReadable: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }
}

// MARK: - the uploads (background URLSession)

/// The uploads, in a background URLSession: they go on with the app suspended. Two sessions, as a
/// session's mobile data rule is fixed: Wi-Fi only, and Wi-Fi + mobile data.
final class BackupUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let wifiID = "ca.channel13.cineme.backup.wifi"
    static let anyID = "ca.channel13.cineme.backup.any"

    /// Every finished upload, also ones started before the app was closed: name, nil or the error.
    /// On the session's queue.
    var onFinished: ((String, Error?) -> Void)?

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private var replies: [String: Data] = [:]
    private var eventsDone: [String: () -> Void] = [:]
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.name = "cineme.backup.upload"; return q
    }()

    func session(_ id: String) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[id] { return s }
        let c = URLSessionConfiguration.background(withIdentifier: id)
        c.allowsCellularAccess = id == BackupUploader.anyID
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        let s = URLSession(configuration: c, delegate: self, delegateQueue: delegateQueue)
        sessions[id] = s
        return s
    }

    /// Uploads [body] (a multipart file, deleted when done) as [name]; returns when the site answered.
    func upload(name: String, body: URL, boundary: String, mobile: Bool) async throws {
        var r = URLRequest(url: BackupAPI.url("upload"))
        r.httpMethod = "POST"
        r.setValue(BackupAPI.auth, forHTTPHeaderField: "Authorization")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let s = session(mobile ? BackupUploader.anyID : BackupUploader.wifiID)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); waiting[name] = c; lock.unlock()
            let t = s.uploadTask(with: r, fromFile: body)
            t.taskDescription = name + "\n" + body.path
            t.resume()
        }
    }

    /// Names still uploading from before (an earlier run, or before the app was closed).
    func inFlight() async -> [String] {
        var names: [String] = []
        for id in [BackupUploader.wifiID, BackupUploader.anyID] {
            for t in await session(id).allTasks where t.state == .running || t.state == .suspended {
                if let n = t.taskDescription?.components(separatedBy: "\n").first { names.append(n) }
            }
        }
        return names
    }

    /// iOS woke the app for this session's events (AppDelegate): [done] once they are handled.
    func handleEvents(_ id: String, _ done: @escaping () -> Void) {
        lock.lock(); eventsDone[id] = done; lock.unlock()
        _ = session(id)
    }

    private func key(_ s: URLSession, _ t: URLSessionTask) -> String { "\(s.configuration.identifier ?? "")#\(t.taskIdentifier)" }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let k = key(session, dataTask)
        lock.lock(); replies[k, default: Data()].append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let parts = (task.taskDescription ?? "").components(separatedBy: "\n")
        let name = parts.first ?? ""
        lock.lock(); let reply = replies.removeValue(forKey: key(session, task)) ?? Data(); lock.unlock()
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var result: Error? = error
        if result == nil, !(200..<300).contains(code) {
            result = BackupError.http(code, String(decoding: reply.prefix(80), as: UTF8.self))
        }
        if parts.count > 1 { try? FileManager.default.removeItem(atPath: parts[1]) }
        onFinished?(name, result)
        lock.lock(); let c = waiting.removeValue(forKey: name); lock.unlock()
        if let e = result { c?.resume(throwing: e) } else { c?.resume() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let id = session.configuration.identifier else { return }
        lock.lock(); let done = eventsDone.removeValue(forKey: id); lock.unlock()
        DispatchQueue.main.async { done?() }
    }
}

// MARK: - the backup

@MainActor
final class Backup: ObservableObject {
    static let shared = Backup()

    /// True while converting or uploading (the small moving arrow left of the level).
    @Published private(set) var busy = false
    /// One line for Settings > Backup.
    @Published private(set) var status = ""
    /// Names marked for deletion on the site, from the last sync.
    @Published private(set) var marked: [String] = []

    let uploader = BackupUploader()
    /// No converting while recording (the encoders and the battery are busy). Set by recordingChanged.
    private(set) var recording = false
    private var running = false
    private var again = false
    private var waitingForNetwork = false
    private var timer: Timer?
    private var afterTake: DispatchWorkItem?
    private var retryLater: DispatchWorkItem?
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var export: AVAssetExportSession?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var durations: [String: Int64] = [:]
    private var fake = false
    private var bgRegistered = false

    private let d = UserDefaults.standard
    private var dir: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// The names already on the site (Android: files/uploaded.txt). Not in Documents, so not in Files.
    private var uploadedFile: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("uploaded.txt")
    }

    private init() {
        // Marked names and the last status from the previous run, so the app shows them before any sync.
        marked = d.stringArray(forKey: "backup.marked") ?? []
        let s = d.string(forKey: "backup.status") ?? ""
        // A run that was stopped halfway leaves "Converting ..." behind; nothing is running now.
        status = s.hasPrefix("Converting") || s.hasPrefix("Uploading") ? "Stopped halfway, goes on at the next sync" : s
        uploader.onFinished = { name, error in
            Task { @MainActor in Backup.shared.uploadFinished(name, error) }
        }
        monitor.pathUpdateHandler = { p in
            Task { @MainActor in Backup.shared.pathChanged(p) }
        }
        monitor.start(queue: DispatchQueue(label: "cineme.backup.net"))
    }

    // MARK: when it runs

    /// Auto upload on: every 15 min while CineMe is open, and now. Off: nothing runs by itself.
    func schedule() {
        timer?.invalidate(); timer = nil
        guard BackupAPI.autoUpload, !fake else { afterTake?.cancel(); retryLater?.cancel(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in Backup.shared.kick() }
        }
        kick()
    }

    /// Recording started or stopped. Stopped: a sync 1 minute later; another take within the minute
    /// starts the minute again, so quick retakes don't keep starting and pausing conversions.
    func recordingChanged(_ on: Bool) {
        let was = recording
        recording = on
        if on { export?.cancelExport() }
        guard was, !on, BackupAPI.autoUpload, !fake else { return }
        afterTake?.cancel()
        let w = DispatchWorkItem { Task { @MainActor in Backup.shared.kick() } }
        afterTake = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    /// Settings > Backup > Sync now (also with auto upload off; same network rule).
    func syncNow() { kick() }

    /// One run soon (after the current one, if any). Waits for Wi-Fi when mobile data isn't allowed.
    func kick() {
        guard !fake else { return }
        if let p = path, !networkOK(p) {
            waitingForNetwork = true
            if !busy { setStatus(BackupAPI.mobile ? "Waiting for a connection" : "Waiting for Wi-Fi (or allow mobile data below)") }
            return
        }
        waitingForNetwork = false
        if running { again = true; return }
        Task { await run() }
    }

    private func networkOK(_ p: NWPath) -> Bool {
        p.status == .satisfied && (BackupAPI.mobile || !p.isExpensive)
    }

    private func pathChanged(_ p: NWPath) {
        path = p
        if waitingForNetwork, networkOK(p) { kick() }
    }

    // MARK: in the background

    /// From the AppDelegate's didFinishLaunching: the BGProcessingTask (only if Info.plist lists it).
    func registerBackgroundTask() {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard ids.contains(BackupAPI.taskID), !bgRegistered else { return }
        bgRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: BackupAPI.taskID, using: nil) { task in
            Task { @MainActor in Backup.shared.runInBackground(task) }
        }
    }

    /// The app goes to the background: ask iOS for a run later (it picks the time).
    func scheduleBackground() {
        guard bgRegistered, BackupAPI.autoUpload, !fake else { return }
        let r = BGProcessingTaskRequest(identifier: BackupAPI.taskID)
        r.requiresNetworkConnectivity = true
        r.requiresExternalPower = false
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(r) } catch { RecLog.w("backup: background run not scheduled: \(error.localizedDescription)") }
    }

    private func runInBackground(_ task: BGTask) {
        scheduleBackground()
        // Wi-Fi only and none now: nothing to do (an upload would only wait).
        if let p = path, !networkOK(p) { task.setTaskCompleted(success: true); return }
        final class Once { var done = false }
        let once = Once()
        let finish: (Bool) -> Void = { ok in
            if once.done { return }
            once.done = true
            task.setTaskCompleted(success: ok)
        }
        let work = Task { await self.run() }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                Backup.shared.export?.cancelExport()
                finish(false)
            }
        }
        Task {
            await work.value
            finish(true)
        }
    }

    /// The app left the screen during a conversion: a little time to finish it, then stop.
    private func beginGrace() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "CineMe backup") {
            MainActor.assumeIsolated { Backup.shared.graceOver() }
        }
    }

    private func graceOver() {
        export?.cancelExport()
        endGrace()
    }

    private func endGrace() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    /// iOS woke the app for a background session (AppDelegate).
    func handleEvents(_ id: String, _ done: @escaping () -> Void) { uploader.handleEvents(id, done) }

    // MARK: the run

    func run() async {
        if recording || running || fake { return }
        running = true
        var retry = false
        defer {
            running = false
            busy = false
            endGrace()
            if again { again = false; kick() }
        }
        do {
            try await reportDeleted()
            let flying = Set(await uploader.inFlight())
            var done = uploaded()
            var fails = d.stringArray(forKey: "backup.fails") ?? []
            while true {
                if recording { setStatus("Paused while recording"); break }
                if Task.isCancelled { break }
                let todo = await local()
                    .filter { item in
                        !done.contains(item.name) && !flying.contains(item.name)
                            && fails.filter { $0.components(separatedBy: "\t").first == item.name }.count < BackupAPI.maxFails
                    }
                    .sorted { $0.taken < $1.taken }
                guard let item = todo.first else { break }
                busy = true
                do {
                    try await upload(item, left: todo.count)
                    done.insert(item.name)
                } catch BackupError.paused {
                    setStatus("Paused while recording")
                    break
                } catch {
                    RecLog.w("backup: \(item.name) failed: \(BackupAPI.describe(error))")
                    if !BackupAPI.isNetwork(error) && !Task.isCancelled {
                        fails.append(item.name + "\t" + String(Int64(Date().timeIntervalSince1970 * 1000)))
                        d.set(fails, forKey: "backup.fails")
                    }
                    setStatus("Failed: \(item.name) (\(BackupAPI.describe(error)))")
                    retry = true
                    break
                }
            }
            busy = false
            await sendSizes()
            try await fetchMarked()
            if !retry && !recording && !Task.isCancelled {
                let have = uploaded()
                let left = await local().filter { !have.contains($0.name) }.count
                let time = Backup.shown.string(from: Date())
                setStatus(left == 0 ? "All uploaded. Last sync \(time)" : "\(left) not uploaded yet. Last sync \(time)")
            }
        } catch {
            setStatus("No connection to the site (\(BackupAPI.describe(error)))")
            retry = true
        }
        // Android's WorkManager retries after a while; here: again in 2 minutes while auto upload is on.
        if retry, BackupAPI.autoUpload, !recording {
            retryLater?.cancel()
            let w = DispatchWorkItem { Task { @MainActor in Backup.shared.kick() } }
            retryLater = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: w)
        }
    }

    private func uploadFinished(_ name: String, _ error: Error?) {
        guard error == nil, !name.isEmpty else { return }
        guard let h = try? FileHandle(forWritingTo: uploadedFile) else {
            try? Data((name + "\n").utf8).write(to: uploadedFile)
            return
        }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((name + "\n").utf8))
    }

    private func uploaded() -> Set<String> {
        guard let s = try? String(contentsOf: uploadedFile, encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    private func setStatus(_ s: String) {
        status = s
        d.set(s, forKey: "backup.status")
    }

    private static let shown: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    // MARK: what gets backed up

    /// CineMe's clips (Documents) and photos (Documents/CineMe Photos: the HEIC / JPEG; the DNG twin
    /// is not uploaded), plus the iPhone camera's photos and videos (Photos, needs read access) if
    /// "Phone camera too" is on, taken since BackupAPI.from. CineMe's own copies in Photos have the
    /// same names, so they count once.
    func local() async -> [LocalItem] {
        if fake { return fakeItems() }
        let from = BackupAPI.from
        var out = files(from)
        if BackupAPI.phoneCamera && BackupAPI.photosReadable { out += assets(from) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.name).inserted }
    }

    private func files(_ from: Date) -> [LocalItem] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        func list(_ folder: URL, _ exts: [String], video: Bool) -> [LocalItem] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return urls.compactMap { u in
                guard exts.contains(u.pathExtension.lowercased()) else { return nil }
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == false { return nil }
                let name = BackupAPI.cleanName(u.lastPathComponent)
                let taken = ClipStore.takenDate(name) ?? v?.creationDate ?? .distantPast
                guard taken >= from else { return nil }
                return LocalItem(source: .file(u), name: name, video: video, taken: taken,
                                 durationMs: durations[name] ?? 0, size: Int64(v?.fileSize ?? 0))
            }
        }
        return list(docs, ["mov", "mp4", "m4v"], video: true) + list(PhotoTaker.folder, ["heic", "jpg", "jpeg"], video: false)
    }

    private func assets(_ from: Date) -> [LocalItem] {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "creationDate >= %@ AND (mediaType == %@ OR mediaType == %@)", from as NSDate,
                                  NSNumber(value: PHAssetMediaType.image.rawValue), NSNumber(value: PHAssetMediaType.video.rawValue))
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var out: [LocalItem] = []
        PHAsset.fetchAssets(with: o).enumerateObjects { a, _, _ in
            if a.mediaSubtypes.contains(.photoScreenshot) { return }
            let res = PHAssetResource.assetResources(for: a)
            guard let r = res.first(where: { $0.type == .photo || $0.type == .video }) ?? res.first else { return }
            out.append(LocalItem(source: .asset(a.localIdentifier), name: BackupAPI.cleanName(r.originalFilename),
                                 video: a.mediaType == .video, taken: a.creationDate ?? .distantPast,
                                 durationMs: Int64(a.duration * 1000), size: 0))
        }
        return out
    }

    /// The clip's length in ms (files only; Photos knows its own). Cached.
    private func duration(_ item: LocalItem) async -> Int64 {
        guard !fake, item.video, case .file(let u) = item.source else { return item.durationMs }
        if let ms = durations[item.name] { return ms }
        guard let t = try? await AVURLAsset(url: u).load(.duration), t.isNumeric else { return 0 }
        let ms = Int64(CMTimeGetSeconds(t) * 1000)
        durations[item.name] = ms
        return ms
    }

    /// "Phone camera too" needs Photos read access: ask (once; then Settings > CineMe > Photos).
    func askPhotos() {
        guard BackupAPI.phoneCamera, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
    }

    // MARK: one item

    private func upload(_ item: LocalItem, left: Int) async throws {
        let fm = FileManager.default
        let base = (item.name as NSString).deletingPathExtension
        let proxy = dir.appendingPathComponent(base + (item.video ? ".mp4" : ".jpg"))
        let thumb = dir.appendingPathComponent(base + ".thumb.jpg")
        let body = dir.appendingPathComponent(base + ".body")
        defer { try? fm.removeItem(at: proxy); try? fm.removeItem(at: thumb) }   // the body goes when the upload ends
        let what = "\(item.name) (\(left) left)"
        setStatus("Converting \(what)")
        beginGrace()

        switch item.source {
        case .file(let u):
            if item.video {
                let a = AVURLAsset(url: u)
                try await videoProxy(a, to: proxy)
                try? await BackupAPI.videoThumb(a, to: thumb)
            } else {
                try await Task.detached {
                    try BackupAPI.jpeg(from: u, maxPx: BackupAPI.photoPx, to: proxy, quality: 0.8)
                    try? BackupAPI.jpeg(from: u, maxPx: 480, to: thumb, quality: 0.75)
                }.value
            }
        case .asset(let id):
            if item.video {
                let a = try await BackupAPI.assetVideo(id)
                try await videoProxy(a, to: proxy)
                try? await BackupAPI.videoThumb(a, to: thumb)
            } else {
                let px = CGFloat(BackupAPI.photoPx)
                try await BackupAPI.assetJPEG(id, size: CGSize(width: px, height: px), fill: false, to: proxy, quality: 0.8)
                try? await BackupAPI.assetJPEG(id, size: CGSize(width: 480, height: 270), fill: true, to: thumb, quality: 0.75)
            }
        }
        if recording { throw BackupError.paused }

        setStatus("Uploading \(what)")
        let ms = await duration(item)
        let fields: [(String, String)] = [
            ("name", item.name),
            ("kind", item.video ? "video" : "photo"),
            ("taken", String(Int64(item.taken.timeIntervalSince1970 * 1000))),
            ("date", Backup.day.string(from: item.taken)),
            ("duration", String(ms)),
            ("orig", String(item.size)),
        ]
        let parts: [(String, URL, String)] = [("file", proxy, item.video ? "video/mp4" : "image/jpeg")]
            + (fm.fileExists(atPath: thumb.path) ? [("thumb", thumb, "image/jpeg")] : [])
        let boundary = "cineme" + String(UInt64(Date().timeIntervalSince1970 * 1e6))
        try await Task.detached { try BackupAPI.writeBody(to: body, boundary: boundary, fields: fields, files: parts) }.value
        try await uploader.upload(name: item.name, body: body, boundary: boundary, mobile: BackupAPI.mobile)
    }

    /// 960x540 H.264 (HDR comes out SDR). Stops if recording starts or the app's time runs out.
    private func videoProxy(_ asset: AVAsset, to out: URL) async throws {
        try? FileManager.default.removeItem(at: out)
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            throw BackupError.cantConvert("can't convert this video")
        }
        s.shouldOptimizeForNetworkUse = true
        export = s
        defer { export = nil }
        do {
            try await s.export(to: out, as: .mp4)
        } catch {
            if recording { throw BackupError.paused }
            throw error
        }
    }

    // MARK: sizes on the site

    /// Original sizes and lengths on the phone, so the site can show them (also fills older uploads).
    private func sendSizes() async {
        let done = uploaded()
        var o: [String: [Int64]] = [:]
        for item in await local() where done.contains(item.name) && item.size > 0 {
            o[item.name] = [item.size, await duration(item)]
        }
        guard !o.isEmpty, let json = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: json, encoding: .utf8) else { return }
        do { _ = try await BackupAPI.fieldsPost("sizes", [("sizes", s)]) } catch { RecLog.w("backup: sizes: \(BackupAPI.describe(error))") }
    }

    // MARK: marked for deletion

    private func fetchMarked() async throws {
        let data = try await BackupAPI.request("marked")
        let names = ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.compactMap { $0 as? String } ?? []
        // Marked here but gone from the phone already: tell the site, it drops its copy. Only names
        // the phone can really see: with "Phone camera too" on but Photos not readable, only CineMe's.
        let onPhone = Set(await local().map { $0.name })
        let complete = !BackupAPI.phoneCamera || BackupAPI.photosReadable
        let gone = names.filter { !onPhone.contains($0) && (complete || $0.hasPrefix("CineMe_")) }
        if !gone.isEmpty { addDeleted(gone); try? await reportDeleted() }
        setMarked(names.filter { !gone.contains($0) })
    }

    /// Only the marked list, no uploads.
    func refreshMarked() async {
        do { try await fetchMarked() } catch { RecLog.w("backup: marked: \(BackupAPI.describe(error))") }
    }

    private func setMarked(_ names: [String]) {
        marked = names
        d.set(names, forKey: "backup.marked")
    }

    /// The marked items still on the phone, oldest first, with their lengths.
    func markedOnPhone() async -> [LocalItem] {
        let m = Set(marked)
        if m.isEmpty { return [] }
        var items = await local().filter { m.contains($0.name) }.sorted { $0.taken < $1.taken }
        for i in items.indices { items[i].durationMs = await duration(items[i]) }
        return items
    }

    /// Deletes them on the phone: CineMe's files (and a photo's DNG twin) go to the video manager's
    /// bin (Documents/.trash, emptied after 30 days); the copies in Photos go to Recently Deleted
    /// after iOS asks. Then tells the site. Returns how many were deleted.
    func deleteFromPhone(_ items: [LocalItem]) async -> Int {
        if fake { setMarked(marked.filter { n in !items.contains { $0.name == n } }); return items.count }
        let fm = FileManager.default
        let bin = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(".trash", isDirectory: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func toBin(_ u: URL) {
            guard fm.fileExists(atPath: u.path) else { return }
            let dest = bin.appendingPathComponent(u.lastPathComponent)
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: u, to: dest)) != nil {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            }
        }
        for item in items {
            guard case .file(let u) = item.source else { continue }
            toBin(u)
            if !item.video { toBin(u.deletingPathExtension().appendingPathExtension("dng")) }
        }
        // The same names in Photos (CineMe's copies, the iPhone camera's).
        var inPhotos: [String: [PHAsset]] = [:]
        if BackupAPI.photosReadable {
            let names = Set(items.map { $0.name })
            let o = PHFetchOptions()
            o.predicate = NSPredicate(format: "creationDate >= %@", BackupAPI.from.addingTimeInterval(-86400) as NSDate)
            PHAsset.fetchAssets(with: o).enumerateObjects { a, _, _ in
                for r in PHAssetResource.assetResources(for: a) where r.type == .photo || r.type == .video {
                    let n = BackupAPI.cleanName(r.originalFilename)
                    if names.contains(n) { inPhotos[n, default: []].append(a) }
                }
            }
        }
        let assets = inPhotos.values.flatMap { $0 }
        var photosOK = true
        if !assets.isEmpty {
            do {
                try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
            } catch {
                photosOK = false
            }
        }
        let done = items.filter { photosOK || inPhotos[$0.name] == nil }.map { $0.name }
        RecLog.w("backup: deleted on the phone: \(done.joined(separator: ", "))")
        await deleted(done)
        return done.count
    }

    /// Deleted on the phone: forget the marks and tell the site (now, or on the next sync if offline).
    func deleted(_ names: [String]) async {
        setMarked(marked.filter { !names.contains($0) })
        addDeleted(names)
        try? await reportDeleted()
    }

    private func addDeleted(_ names: [String]) {
        let have = d.stringArray(forKey: "backup.deleted") ?? []
        d.set(Array(Set(have + names)), forKey: "backup.deleted")
    }

    private func reportDeleted() async throws {
        let names = d.stringArray(forKey: "backup.deleted") ?? []
        if names.isEmpty || fake { return }
        let data = try JSONSerialization.data(withJSONObject: names)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        _ = try await BackupAPI.request("deleted", form: "names=" + (json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
        let now = d.stringArray(forKey: "backup.deleted") ?? []
        d.set(now.filter { !names.contains($0) }, forKey: "backup.deleted")
    }

    /// A small picture of an item, for the marked list.
    func preview(_ item: LocalItem) async -> UIImage? {
        switch item.source {
        case .asset(let id):
            return try? await BackupAPI.assetImage(id, size: CGSize(width: 320, height: 180), fill: true)
        case .file(let u):
            if item.video {
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
                g.appliesPreferredTrackTransform = true
                g.maximumSize = CGSize(width: 320, height: 320)
                guard let cg = try? await g.image(at: .zero).image else { return nil }
                return UIImage(cgImage: cg)
            }
            let o: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    // MARK: screenshot runs

    /// -shot backup / marked: a status and three marked items, nothing on disk or on the network.
    func fakeForShots() {
        fake = true
        timer?.invalidate()
        busy = true
        status = "All uploaded. Last sync 22 Nov 14:05"
        marked = fakeItems().map { $0.name }
    }

    private func fakeItems() -> [LocalItem] {
        let tmp = FileManager.default.temporaryDirectory
        let cal = Calendar.current
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m)) ?? Date() }
        return [
            LocalItem(source: .file(tmp.appendingPathComponent("CineMe_20261121_101502.mov")), name: "CineMe_20261121_101502.mov",
                      video: true, taken: at(21, 10, 15), durationMs: 42_000, size: 812_000_000, hue: 0.55),
            LocalItem(source: .file(tmp.appendingPathComponent("CineMe_20261121_103318_204.heic")), name: "CineMe_20261121_103318_204.heic",
                      video: false, taken: at(21, 10, 33), durationMs: 0, size: 4_100_000, hue: 0.08),
            LocalItem(source: .asset("fake"), name: "IMG_4127.MOV", video: true, taken: at(21, 16, 2),
                      durationMs: 185_000, size: 0, hue: 0.33),
        ]
    }
}

/// For the SwiftUI app: background upload events and the BGProcessingTask need an app delegate.
/// CineMeApp: @UIApplicationDelegateAdaptor(BackupAppDelegate.self) var appDelegate
final class BackupAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        RecLog.start()
        Backup.shared.registerBackgroundTask()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Backup.shared.handleEvents(identifier, completionHandler)
    }
}

// MARK: - screens

/// The small moving arrow left of the level while converting or uploading.
struct BackupBusyIcon: View {
    @ObservedObject var backup = Backup.shared
    @State private var up = false
    var body: some View {
        if backup.busy {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.brass)
                .offset(y: up ? -4 : 4)
                .frame(width: 30, height: 40)
                .background(Capsule().fill(Color.plate))
                .clipShape(Capsule())
                .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { up = true } }
                .onDisappear { up = false }
        }
    }
}

/// Settings > Backup (Android Group("Backup") :1951): On / Off rows, the status in Dim, Sync now and
/// the marked list as pills, the notes.
struct BackupView: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var backup = Backup.shared
    @AppStorage(BackupAPI.autoKey) private var auto = true
    @AppStorage(BackupAPI.cameraKey) private var phoneCamera = true
    @AppStorage(BackupAPI.mobileKey) private var mobile = false
    @State private var showMarked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneOnOff("Auto upload", isOn: $auto)
            PaneOnOff("Phone camera too", isOn: $phoneCamera)
            PaneOpt("Upload on", [false, true], mobile, title: { $0 ? "Wi-Fi + mobile data" : "Wi-Fi only" }) { mobile = $0 }
            if !backup.status.isEmpty {
                Text(backup.status).font(s.font(14)).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, s(4))
            }
            FlowRow(spacing: s(6), lineSpacing: s(6)) {
                CinePill("Sync now") { backup.askPhotos(); backup.syncNow() }
                if !backup.marked.isEmpty {
                    CinePill("Marked to delete: \(backup.marked.count)") { showMarked = true }
                }
            }
            .padding(.top, s(6))
            CineNote("Everything taken since \(BackupAPI.from.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) is backed up.")
            CineNote("Small copies (540p video, 1600 px photos) go to cineme.studiowebworks.com/videos. Delete there only marks; the iPhone shows the marked ones and asks twice before deleting. Phone camera too needs access to all of Photos.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: auto) { _, on in if on { backup.askPhotos() }; backup.schedule() }
        .onChange(of: phoneCamera) { _, _ in backup.askPhotos() }
        .onChange(of: mobile) { _, _ in backup.schedule() }
        .sheet(isPresented: $showMarked) {
            NavigationStack { MarkedView(onClose: { showMarked = false }) }
        }
    }
}

/// The Backup page on its own (old `.sheet { BackupSheet() }` callers, -shot backup).
struct BackupSheet: View {
    var body: some View {
        SettingsPageSheet(title: "Backup") { BackupView() }
    }
}

/// The items marked for deletion on the site that are still on the phone: a frame and the name of
/// each, "Delete all" and then a second Yes.
struct MarkedView: View {
    var onClose: (() -> Void)? = nil
    @ObservedObject var backup = Backup.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [LocalItem] = []
    @State private var sure = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Still on the phone. Nothing is deleted until you say yes twice.")
                .font(.system(size: 14)).foregroundStyle(Color.dim)
                .padding(.horizontal, 20).padding(.top, 8)
            List(items) { item in
                HStack(spacing: 14) {
                    MarkedThumb(item: item)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 15)).foregroundStyle(Color.ivory)
                        Text(kind(item)).font(.system(size: 13)).foregroundStyle(Color.dim)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            HStack(spacing: 16) {
                Button { sure = true } label: {
                    Text("Delete all \(items.count)").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 28).frame(height: 56)
                        .background(Capsule().fill(Color.rec))
                }
                .disabled(items.isEmpty || working)
                Button { close() } label: {
                    Text("Later").font(.system(size: 17)).foregroundStyle(Color.ivory)
                        .padding(.horizontal, 22).frame(height: 48)
                        .background(Capsule().fill(Color.plate))
                }
            }
            .padding(20)
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .navigationTitle("Marked to delete: \(items.count)")
        .alert("Delete \(items.count) from the phone?", isPresented: $sure) {
            Button("Yes", role: .destructive) { deleteAll() }
            Button("No", role: .cancel) {}
        } message: {
            Text("CineMe's files go to its bin (30 days). For the ones in Photos, iOS asks once more.")
        }
        .task { items = await backup.markedOnPhone() }
    }

    private func kind(_ i: LocalItem) -> String {
        if !i.video { return "Photo" }
        return i.durationMs > 0 ? "Video " + clipClock(Double(i.durationMs) / 1000) : "Video"
    }

    private func deleteAll() {
        working = true
        Task {
            _ = await backup.deleteFromPhone(items)
            items = await backup.markedOnPhone()
            working = false
            if items.isEmpty { close() }
        }
    }

    private func close() {
        if let c = onClose { c() } else { dismiss() }
    }
}

private struct MarkedThumb: View {
    let item: LocalItem
    @State private var img: UIImage? = nil
    var body: some View {
        ZStack {
            if let h = item.hue { LibFakeFrame(hue: h) }
            else if let i = img { Image(uiImage: i).resizable().scaledToFill() }
            else { Color(white: 0.15) }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { if item.hue == nil { img = await Backup.shared.preview(item) } }
    }
}

/// On the camera screen: when the site has marked items still on the phone, the list comes up by
/// itself (not while recording). Later = not again until the list changes.
struct MarkedPrompt: ViewModifier {
    let recording: Bool
    @ObservedObject var backup = Backup.shared
    @State private var show = false
    @State private var laterFor: [String] = []

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $show, onDismiss: { laterFor = backup.marked }) {
                NavigationStack { MarkedView(onClose: { show = false }) }
            }
            .onChange(of: backup.marked) { _, _ in check() }
            .onChange(of: recording) { _, _ in check() }
    }

    private func check() {
        guard Shot.screen == nil, !recording, !show, !backup.marked.isEmpty, backup.marked != laterFor else { return }
        show = true
    }
}

extension View {
    /// The marked-for-deletion list, by itself when needed (MarkedPrompt).
    func backupMarkedPrompt(recording: Bool) -> some View { modifier(MarkedPrompt(recording: recording)) }
}

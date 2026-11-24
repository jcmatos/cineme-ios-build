import AVFoundation
import Combine
import SwiftUI
import UIKit

// The video manager: the clips in the app's Documents folder as a grid, with stars, in / out points,
// a bin with undo, and the order. Port of the Android Library.kt + PlayerActivity.kt.

// MARK: - model

/// One clip in the app's Documents folder.
struct LibClip: Identifiable, Equatable {
    let url: URL
    let name: String
    /// When it was filmed: from the name (CineMe_yyyyMMdd_HHmmss), else the file's date.
    let taken: Date
    let bytes: Int64
    /// A made-up tile for simulator screenshots (no file behind it).
    var fake = false
    /// Fake tiles only: their colour.
    var hue: Double = 0
    var id: String { name }
}

/// Star (keep: can't be deleted) and the in / out points in seconds (-1 = not set).
struct ClipMark: Equatable {
    var star = false
    var inS: Double = -1
    var outS: Double = -1
    var hasRange: Bool { inS >= 0 && outS > inS }
}

/// How the clips are ordered (the sort button).
enum ClipSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case biggest = "Biggest file first"
    case smallest = "Smallest file first"
    case longest = "Longest first"
    case shortest = "Shortest first"
    case starred = "Starred first, then newest"
    case nameAZ = "Name A to Z"
    case nameZA = "Name Z to A"
    var id: String { rawValue }
}

/// Gimbal keys while the library is open (CineMeApp sends them here instead of to the camera).
enum LibKey { case click, forward, back, fastForward, fastBack, letGo }

final class LibraryRemote {
    static let shared = LibraryRemote()
    /// True while the library is on screen: gimbal keys go to [send], not to the camera.
    fileprivate(set) var isOpen = false
    let keys = PassthroughSubject<LibKey, Never>()
    func send(_ k: LibKey) { DispatchQueue.main.async { self.keys.send(k) } }
}

/// The clips, their marks, the bin and the undo history. One for the whole app, so the sound and
/// the order are kept while the app is open (like Android).
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    struct UndoStep {
        let label: String
        let isDelete: Bool
        let run: () -> Void
    }

    @Published private(set) var clips: [LibClip] = []
    @Published private(set) var marks: [String: ClipMark] = [:]
    /// Clip lengths in seconds, filled in the background.
    @Published private(set) var seconds: [String: Double] = [:]
    @Published private(set) var undo: [UndoStep] = []
    @Published private(set) var binCount = 0
    @Published private(set) var binBytes: Int64 = 0
    /// Sound is off until turned on.
    @Published var sound = false
    @Published var sort: ClipSort = .newest
    /// A short note at the bottom (deleted, undone...).
    @Published var message: String? = nil
    @Published private(set) var messageID = 0

    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var bin: URL { folder.appendingPathComponent(".trash", isDirectory: true) }
    /// Same format as Android's marks, so the PC Video Manager can read it: {"name": {"star": true, "in": 1.2, "out": 4.0}}.
    private var marksFile: URL { folder.appendingPathComponent("cineme-marks.json") }
    /// Clips stay in the bin this long, then go for good.
    private let binDays: Double = 30
    private let thumbs = NSCache<NSString, UIImage>()
    private var loadingLengths = false
    /// Only sample tiles are shown: nothing is written to disk.
    private var samplesOnly = false
    private var shotRun: Bool { Shot.screen == "library" || Shot.screen == "player" }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func takenDate(_ name: String) -> Date? {
        guard let r = name.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        return stamp.date(from: String(name[r]))
    }

    // MARK: list

    /// Reads the folder again. Main thread.
    func reload() {
        loadMarks()
        samplesOnly = false
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var list: [LibClip] = []
        for u in urls where ["mov", "mp4", "m4v"].contains(u.pathExtension.lowercased()) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == false { continue }
            let name = u.lastPathComponent
            list.append(LibClip(url: u, name: name, taken: Self.takenDate(name) ?? v?.creationDate ?? .distantPast,
                                bytes: Int64(v?.fileSize ?? 0)))
        }
        if list.isEmpty && shotRun { list = samples() }
        clips = list
        purgeBin()
        countBin()
        loadLengths()
    }

    func mark(_ name: String) -> ClipMark { marks[name] ?? ClipMark() }
    func length(_ c: LibClip) -> Double { seconds[c.name] ?? 0 }

    /// In the chosen order; only the starred ones if [starredOnly].
    func sorted(starredOnly: Bool) -> [LibClip] {
        let l = starredOnly ? clips.filter { mark($0.name).star } : clips
        switch sort {
        case .newest: return l.sorted { $0.taken > $1.taken }
        case .oldest: return l.sorted { $0.taken < $1.taken }
        case .biggest: return l.sorted { $0.bytes > $1.bytes }
        case .smallest: return l.sorted { $0.bytes < $1.bytes }
        case .longest: return l.sorted { length($0) > length($1) }
        case .shortest: return l.sorted { length($0) < length($1) }
        case .starred:
            return l.sorted {
                let a = mark($0.name).star, b = mark($1.name).star
                return a != b ? a : $0.taken > $1.taken
            }
        case .nameAZ: return l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameZA: return l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
    }

    /// Lengths of the clips not known yet, in the background.
    private func loadLengths() {
        guard !loadingLengths else { return }
        let todo = clips.filter { !$0.fake && seconds[$0.name] == nil }
        guard !todo.isEmpty else { return }
        loadingLengths = true
        Task {
            var found: [String: Double] = [:]
            for (i, c) in todo.enumerated() {
                if let d = try? await AVURLAsset(url: c.url).load(.duration), d.isNumeric { found[c.name] = d.seconds }
                if found.count >= 16 || i == todo.count - 1 {
                    let batch = found
                    found = [:]
                    await MainActor.run { self.seconds.merge(batch) { $1 } }
                }
            }
            await MainActor.run { self.loadingLengths = false }
        }
    }

    /// A still from the clip, cached.
    func thumbnail(_ c: LibClip) async -> UIImage? {
        let key = c.name as NSString
        if let i = thumbs.object(forKey: key) { return i }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: c.url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 640, height: 640)
        for t in [0.5, 0.0] {
            if let cg = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let img = UIImage(cgImage: cg)
                thumbs.setObject(img, forKey: key)
                return img
            }
        }
        return nil
    }

    // MARK: marks

    /// Sets a clip's mark; the step back goes into the undo history.
    func setMark(_ name: String, _ m: ClipMark, label: String) {
        let before = mark(name)
        putMark(name, m)
        remember(label, isDelete: false) { [weak self] in self?.putMark(name, before) }
    }

    private func putMark(_ name: String, _ m: ClipMark) {
        marks[name] = m == ClipMark() ? nil : m
        saveMarks()
    }

    private func loadMarks() {
        guard let data = try? Data(contentsOf: marksFile),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { marks = [:]; return }
        var m: [String: ClipMark] = [:]
        for (k, v) in o {
            guard let d = v as? [String: Any] else { continue }
            let mk = ClipMark(star: d["star"] as? Bool ?? false, inS: d["in"] as? Double ?? -1, outS: d["out"] as? Double ?? -1)
            if mk != ClipMark() { m[k] = mk }
        }
        marks = m
    }

    private func saveMarks() {
        if samplesOnly { return }
        var o: [String: Any] = [:]
        for (k, v) in marks {
            var d: [String: Any] = ["star": v.star]
            if v.inS >= 0 { d["in"] = (v.inS * 1000).rounded() / 1000 }
            if v.outS >= 0 { d["out"] = (v.outS * 1000).rounded() / 1000 }
            o[k] = d
        }
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: marksFile, options: .atomic)
        }
    }

    // MARK: undo, messages

    func remember(_ label: String, isDelete: Bool, _ run: @escaping () -> Void) {
        undo.append(UndoStep(label: label, isDelete: isDelete, run: run))
        if undo.count > 50 { undo.removeFirst(undo.count - 50) }
    }

    /// Undoes the newest step.
    func undoLast() {
        guard let s = undo.popLast() else { say("Nothing to undo"); return }
        s.run()
        say("Undone: \(s.label)")
    }

    func say(_ m: String) {
        message = m
        messageID += 1
    }

    // MARK: bin

    /// To the bin (Documents/.trash), with undo. A starred clip stays.
    func trash(_ c: LibClip) {
        if mark(c.name).star { say("Starred: un-star it first"); return }
        if c.fake {
            clips.removeAll { $0.name == c.name }
            remember("clip deleted", isDelete: true) { [weak self] in self?.clips.append(c) }
            say("Clip deleted (undo: the arrow)")
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent(c.name)
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: c.url, to: dest) } catch { say("Couldn't delete it"); return }
        // The bin empties by this date.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        clips.removeAll { $0.name == c.name }
        countBin()
        say("Clip deleted (undo: the arrow)")
        remember("clip deleted", isDelete: true) { [weak self] in self?.restore(c) }
    }

    private func restore(_ c: LibClip) {
        let fm = FileManager.default
        let src = bin.appendingPathComponent(c.name)
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: c.url.path) else { return }
        try? fm.moveItem(at: src, to: c.url)
        if !clips.contains(where: { $0.name == c.name }) { clips.append(c) }
        countBin()
    }

    /// Deletes what's in the bin for good.
    func emptyBin() {
        for u in binFiles() { try? FileManager.default.removeItem(at: u) }
        undo.removeAll { $0.isDelete }
        countBin()
        say("Bin emptied")
    }

    private func binFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private func purgeBin() {
        let limit = Date().addingTimeInterval(-binDays * 86400)
        for u in binFiles() {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if d < limit { try? FileManager.default.removeItem(at: u) }
        }
    }

    private func countBin() {
        let files = binFiles()
        binCount = files.count
        binBytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    // MARK: screenshot samples

    /// Simulator screenshots (-shot library / player): made-up tiles, nothing on disk.
    private func samples() -> [LibClip] {
        samplesOnly = true
        let lengths: [Double] = [42, 8, 125, 17, 63, 5, 31, 210, 12, 76, 24, 9]
        let now = Date()
        var out: [LibClip] = []
        for (i, s) in lengths.enumerated() {
            let d = now.addingTimeInterval(Double(-i) * 1900)
            let name = "CineMe_\(Self.stamp.string(from: d)).mov"
            out.append(LibClip(url: folder.appendingPathComponent(name), name: name, taken: d, bytes: Int64(s * 45_000_000),
                               fake: true, hue: Double(i) / Double(lengths.count)))
            seconds[name] = s
        }
        marks[out[1].name] = ClipMark(star: true)
        marks[out[4].name] = ClipMark(star: true, inS: 12, outS: 30)
        marks[out[6].name] = ClipMark(inS: 4, outS: 11)
        return out
    }
}

// MARK: - the grid (Library.kt LibraryGrid)

/// The video manager, full screen, as Android's: a grid of 2 to 6 across (− / + or pinch), scroll for
/// more. Landscape: key columns at both sides, the tiles fill the height (rows = columns). Portrait: a
/// bar on top and one at the bottom. Tap a tile: it plays there; drag on it while it plays: scrub;
/// double tap or its corner key: full screen. Present it with .fullScreenCover; X = dismiss.
struct LibraryView: View {
    @ObservedObject private var store = ClipStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("libCols") private var cols = 2
    @State private var starredOnly = false
    @State private var compare = false
    @State private var sorting = false
    @State private var help = false
    @State private var emptying = false
    /// The tile playing (tapped): one at a time.
    @State private var active: String? = nil
    /// The last tile touched: the single-view key opens it.
    @State private var picked: String? = nil
    /// The clip in the player (nil = the grid).
    @State private var open: String? = nil
    @State private var scrollTarget: String? = nil
    @State private var pinchBase: CGFloat = 1
    private let s = CineScale.player

    init() {}

    private static let minCols = 2
    private static let maxCols = 6
    private var n: Int { min(max(cols, Self.minCols), Self.maxCols) }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let shown = store.sorted(starredOnly: starredOnly)
            ZStack {
                Color.black.ignoresSafeArea()
                grid(shown, size: geo.size, insets: geo.safeAreaInsets, landscape: landscape)
                if shown.isEmpty {
                    Text(starredOnly ? "No starred clips" : "No clips yet").font(s.font(15)).foregroundStyle(Color.dim)
                }
                if landscape { sideKeys(shown) } else { barKeys(shown) }
                if sorting { sortPopup }
                if open == nil { toast(landscape) }
                if let name = open {
                    // All clips (not only the starred), like Android.
                    ClipPlayer(clips: store.sorted(starredOnly: false), start: name,
                               onGrid: { n in open = nil; scrollTarget = n; picked = n },
                               onHelp: { help = true },
                               onClose: { dismiss() })
                }
                if help {
                    LibraryHelp(binText: store.binCount > 0 ? binText : nil, onEmpty: { emptying = true }, onClose: { help = false })
                }
                if emptying {
                    CineConfirmDialog("Empty the bin?", binText,
                                      onYes: { store.emptyBin(); emptying = false },
                                      onNo: { emptying = false })
                }
            }
        }
        .cineScale(.player)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task(id: store.messageID) {
            guard store.message != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { store.message = nil }
        }
        .onAppear {
            LibraryRemote.shared.isOpen = true
            store.reload()
            if Shot.screen == "player" { open = store.sorted(starredOnly: false).first?.name }
        }
        .onDisappear { LibraryRemote.shared.isOpen = false }
    }

    private var binText: String {
        let c = store.binCount == 1 ? "1 clip" : "\(store.binCount) clips"
        let size = ByteCountFormatter.string(fromByteCount: store.binBytes, countStyle: .file)
        return "\(c), \(size). They can't come back."
    }

    // MARK: grid

    private func grid(_ shown: [LibClip], size: CGSize, insets: EdgeInsets, landscape: Bool) -> some View {
        let gap = s(8)
        let k = CGFloat(n)
        let tileW: CGFloat
        if landscape {
            // Rows = columns: the tiles' height fills the screen between the side columns.
            let fullH = size.height + insets.top + insets.bottom
            let h = (fullH - s(16) - gap * (k - 1)) / k
            tileW = max(10, min(h * 16 / 9, (size.width - s(76) * 2 - gap * (k - 1)) / k))
        } else {
            tileW = max(10, (size.width - s(16) - gap * (k - 1)) / k)
        }
        let side = max(s(8), (size.width - tileW * k - gap * (k - 1)) / 2)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileW), spacing: gap), count: n), spacing: gap) {
                    ForEach(shown) { c in
                        ClipTile(clip: c, width: tileW, active: active == c.name, compare: compare && n <= 2,
                                 small: n >= 4, tiny: n >= 5,
                                 onActivate: { active = c.name; picked = c.name },
                                 onOpen: { picked = c.name; active = nil; open = c.name })
                            .id(c.name)
                    }
                }
                .padding(.horizontal, side)
                .padding(.top, landscape ? s(8) : s(64 + 8))
                .padding(.bottom, landscape ? s(12) : s(64 + 12))
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: landscape ? .vertical : [])
            .onChange(of: scrollTarget) { _, t in
                guard let t else { return }
                proxy.scrollTo(t, anchor: .center)
                scrollTarget = nil
            }
        }
        .simultaneousGesture(pinch)
        .animation(.easeInOut(duration: 0.25), value: n)
    }

    /// Pinch: bigger / smaller tiles.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let k = v.magnification / pinchBase
                if k > 1.3, n > Self.minCols { cols = n - 1; pinchBase = v.magnification }
                else if k < 0.77, n < Self.maxCols { cols = n + 1; pinchBase = v.magnification }
            }
            .onEnded { _ in pinchBase = 1 }
    }

    // MARK: keys (Library.kt:311-348)

    private func sideKeys(_ shown: [LibClip]) -> some View {
        HStack(spacing: 0) {
            // Left: what's shown and how big; right: views, sound, undo, help, close.
            VStack(spacing: s(10)) {
                Text("\(shown.count)").font(s.font(14)).foregroundStyle(Color.dim)
                starKey; compareKey; moreKey; lessKey; sortKey
            }
            Spacer(minLength: 0)
            VStack(spacing: s(10)) {
                closeKey; singleKey(shown); soundKey; undoKey; helpKey
            }
        }
        .padding(.horizontal, s(8))
    }

    private func barKeys(_ shown: [LibClip]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                starKey; Spacer(minLength: 0); compareKey; Spacer(minLength: 0); lessKey; Spacer(minLength: 0)
                moreKey; Spacer(minLength: 0); sortKey; Spacer(minLength: 0); closeKey
            }
            .padding(.horizontal, s(8))
            .frame(maxWidth: .infinity)
            .frame(height: s(64))
            .background(Color.libraryBar.ignoresSafeArea(edges: .top))
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0); soundKey; Spacer(minLength: 0); undoKey; Spacer(minLength: 0)
                singleKey(shown); Spacer(minLength: 0); helpKey; Spacer(minLength: 0)
            }
            .padding(.horizontal, s(8))
            .frame(maxWidth: .infinity)
            .frame(height: s(64))
            .background(Color.libraryBar.ignoresSafeArea(edges: .bottom))
        }
    }

    /// Library.kt BarButton: 52dp, 1dp Edge, StarAmber when on, 0.35 when disabled.
    private func barKey<C: View>(on: Bool = false, enabled: Bool = true, action: @escaping () -> Void,
                                 @ViewBuilder _ content: @escaping () -> C) -> some View {
        CineRoundKey(size: 52, fill: on ? Color.starAmber : Color.plate, enabled: enabled, disabledAlpha: 0.35,
                     action: action, content: content)
    }

    // Starred-only on: a black star on the amber (Android draws it amber on amber, invisible).
    private var starKey: some View {
        barKey(on: starredOnly, action: { starredOnly.toggle() }) {
            CineIcon(.star(filled: starredOnly), size: 22, color: starredOnly ? Color.black : Color.ivory)
        }
    }
    private var compareKey: some View {
        barKey(on: compare, action: {
            compare.toggle()
            if compare && n > 2 { cols = 2 }
        }) { CineIcon(.compare, color: compare ? Color.black : Color.ivory) }
    }
    private var lessKey: some View {
        barKey(enabled: n < Self.maxCols, action: { cols = n + 1 }) { Text("−").font(s.font(24)).foregroundStyle(Color.ivory) }
    }
    private var moreKey: some View {
        barKey(enabled: n > Self.minCols, action: { cols = n - 1 }) { Text("+").font(s.font(24)).foregroundStyle(Color.ivory) }
    }
    private var sortKey: some View {
        barKey(on: sorting, action: { sorting = true }) { CineIcon(.sort) }
    }
    private var soundKey: some View {
        barKey(on: store.sound, action: { store.sound.toggle() }) {
            CineIcon(.speaker(muted: !store.sound), color: store.sound ? Color.black : Color.ivory)
        }
    }
    private var undoKey: some View {
        barKey(enabled: !store.undo.isEmpty, action: { store.undoLast() }) { CineIcon(.undo) }
    }
    private var helpKey: some View {
        barKey(action: { help = true }) { Text("?").font(s.font(20)).foregroundStyle(Color.ivory) }
    }
    private var closeKey: some View {
        barKey(action: { dismiss() }) { CineIcon(.cross, size: 18) }
    }
    private func singleKey(_ shown: [LibClip]) -> some View {
        barKey(enabled: !shown.isEmpty, action: {
            let name = picked.flatMap { p in store.clips.contains { $0.name == p } ? p : nil } ?? shown.first?.name
            active = nil
            open = name
        }) { CineIcon(.single) }
    }

    // MARK: sort popup, message

    /// The order popup (Library.kt:359-371): one tap picks.
    private var sortPopup: some View {
        CineScrim(color: .scrimDark, onTapOutside: { sorting = false }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("ORDER").font(s.font(13)).foregroundStyle(Color.brass)
                    .padding(.horizontal, s(22)).padding(.vertical, s(6))
                ForEach(ClipSort.allCases) { o in
                    Button {
                        store.sort = o
                        sorting = false
                    } label: {
                        Text(o.rawValue).font(s.font(17)).foregroundStyle(store.sort == o ? Color.starAmber : Color.ivory)
                            .padding(.horizontal, s(22)).padding(.vertical, s(10))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CinePressStyle())
                }
            }
            .padding(.vertical, s(10))
            .fixedSize()
            .plate(cineRect(s(16)), fill: Color.sortCard, border: Color.edge)
        }
    }

    @ViewBuilder private func toast(_ landscape: Bool) -> some View {
        if let m = store.message {
            VStack {
                Spacer()
                Text(m).font(s.font(15)).foregroundStyle(Color.ivory)
                    .padding(.horizontal, s(20)).padding(.vertical, s(10))
                    .background(Capsule().fill(Color.toastBack))
                    .overlay(Capsule().strokeBorder(Color.edge, lineWidth: s(1)))
                    .padding(.bottom, landscape ? s(24) : s(64 + 16))
            }
            .allowsHitTesting(false)
        }
    }
}

/// The player's help ("?"), as Android's HelpSheet (Help.kt:31-53) with the player's part, plus the
/// iPhone's own bin (Android uses the phone's trash): its "Empty the bin" key lives here.
struct LibraryHelp: View {
    /// "N clips, size. They can't come back." or nil when the bin is empty.
    let binText: String?
    let onEmpty: () -> Void
    let onClose: () -> Void
    private let s = CineScale.player

    var body: some View {
        ZStack(alignment: .top) {
            Color.sheet.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Help").font(s.font(26, .medium)).foregroundStyle(Color.ivory)
                    Spacer()
                    CineCloseKey(size: 52, cross: 20, border: nil, action: onClose)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(libraryHelp.enumerated()), id: \.offset) { _, sec in
                            Spacer().frame(height: s(18))
                            title(sec.0)
                            ForEach(Array(sec.1.enumerated()), id: \.offset) { _, line in bullet(line) }
                        }
                        Spacer().frame(height: s(18))
                        title("BIN")
                        bullet(binText.map { "In the bin: \($0)" } ?? "The bin is empty.")
                        CinePill("Empty the bin", enabled: binText != nil, action: onEmpty)
                            .padding(.top, s(10))
                        Spacer().frame(height: s(40))
                    }
                    .frame(maxWidth: s(760), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, s(36))
            .padding(.vertical, s(18))
        }
    }

    private func title(_ t: String) -> some View {
        Text(t).font(s.font(14, .medium)).tracking(s.tracking(0.1, sp: 14)).foregroundStyle(Color.brass)
    }

    private func bullet(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("•").font(s.font(15)).foregroundStyle(Color.dim).padding(.trailing, s(10))
            Text(line).font(s.font(15)).foregroundStyle(Color.ivory).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, s(6))
    }
}

/// Android's PLAYER_HELP (Help.kt:58), as the iPhone does it.
let libraryHelp: [(String, [String])] = [
    ("PLAYER", [
        "Opens as a grid. − / + (or pinch) shows more or fewer at a time; scroll for more. Tap a clip: it plays there; drag on it while it plays: scrub; double tap: full screen. The rectangle: the last one touched, full screen.",
        "Order button (two arrows): newest / oldest, biggest / smallest file, longest / shortest, starred first, name.",
        "Sound is off until you turn it on with the speaker (grid or full screen). The curved arrow undoes the last steps (delete, star, in / out), one per tap.",
        "Star (top right of a tile): keep it. A starred clip can't be deleted until the star is taken off. The star at the top shows only the starred ones.",
        "Bin: to CineMe's bin (kept 30 days), with Undo. Empty the bin at the bottom of this page.",
        "Compare: the clips on screen play side by side, muted (2 across).",
        "Full screen: grid button back, sound, previous (older), next (newer), delete. Top right: star, map (where it was filmed, Apple Maps), X closes.",
        "In / out (the brackets at the side): in = the frame on screen, and the out point goes 1 s later; out moves only the end, so the part can be made longer. X clears them. Green on the bar and on the tile.",
        "Drag left / right to scrub: one screen width = the whole clip. Tap to pause.",
    ]),
    ("PLAYER, FROM THE GIMBAL", [
        "W / T short push: 2 s forward / back.",
        "W / T held: fast forward / back, faster every second (2x up to 32x). Let go to stop.",
        "Record: next clip. Two fast clicks: previous clip.",
        "Don't hold record alone: a long press turns the gimbal off.",
    ]),
]

// MARK: - a tile (Library.kt Tile)

/// One clip: a still (or the clip playing, when tapped or in Compare), its length, star (top right),
/// full screen (bottom left), bin (bottom right), the position (Brass) and the in / out part (green)
/// along the bottom. Tap = play / pause here, double tap = full screen, drag while playing = scrub.
private struct ClipTile: View {
    let clip: LibClip
    let width: CGFloat
    let active: Bool
    let compare: Bool
    let small: Bool
    let tiny: Bool
    let onActivate: () -> Void
    let onOpen: () -> Void
    @ObservedObject private var store = ClipStore.shared
    @State private var thumb: UIImage? = nil
    @State private var refused = false
    /// 1 = there, 0 = gone (the delete shrinks and fades it, 260 ms).
    @State private var k: Double = 1
    /// The player while the tile is live.
    @State private var ctl: TilePlayer? = nil
    @State private var scrub: (from: Double, wasPlaying: Bool)? = nil
    @State private var scrubSideways: Bool? = nil
    private let s = CineScale.player

    init(clip: LibClip, width: CGFloat, active: Bool, compare: Bool, small: Bool, tiny: Bool,
         onActivate: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.clip = clip; self.width = width; self.active = active; self.compare = compare
        self.small = small; self.tiny = tiny; self.onActivate = onActivate; self.onOpen = onOpen
    }

    private var live: Bool { !clip.fake && (active || compare) }
    private var sound: Bool { active && !compare && store.sound }

    var body: some View {
        let mark = store.mark(clip.name)
        let shape = cineRect(s(10))
        let h = width * 9 / 16
        ZStack {
            Color.tile
            picture
            if let c = ctl, live {
                TileLive(ctl: c, mark: mark, length: store.length(clip), small: small, tiny: tiny)
            } else {
                still(mark)
            }
            if tiny {
                if mark.star {
                    CineIcon(.star(filled: true), size: 14, color: Color.starAmber)
                        .padding(s(4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            } else {
                corners(mark)
            }
            if refused {
                Text("Starred: un-star it first").font(s.font(13)).foregroundStyle(Color.ivory)
                    .padding(.horizontal, s(12)).padding(.vertical, s(6))
                    .background(Capsule().fill(Color(argb: 0xE0000000)))
            }
        }
        .frame(width: width, height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(active ? Color.ivory : mark.star ? Color.starAmber : Color.edge,
                                    lineWidth: s(active || mark.star ? 2 : 1)))
        .contentShape(shape)
        .scaleEffect(0.6 + 0.4 * k)
        .opacity(k)
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture {
            if !active { onActivate() } else { ctl?.toggle() }
        }
        .simultaneousGesture(scrubGesture, including: live ? .all : .subviews)
        .task(id: clip.name) {
            if !clip.fake { thumb = await store.thumbnail(clip) }
        }
        .task(id: refused) {
            guard refused else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { refused = false }
        }
        .onAppear { syncPlayer() }
        .onDisappear { ctl?.stop(); ctl = nil }
        .onChange(of: live) { _, _ in syncPlayer() }
        .onChange(of: sound) { _, v in ctl?.setMuted(!v) }
        .onChange(of: mark) { _, m in ctl?.mark = m }
    }

    @ViewBuilder private var picture: some View {
        if clip.fake {
            LibFakeFrame(hue: clip.hue)
        } else if let t = thumb {
            Image(uiImage: t).resizable().scaledToFill().frame(width: width, height: width * 9 / 16).clipped()
        }
    }

    /// Not playing: the length chip and the in / out line.
    @ViewBuilder private func still(_ mark: ClipMark) -> some View {
        let len = store.length(clip)
        ZStack {
            if !tiny && len > 0 { TileChip(text: clipClock(len), small: small) }
            if len > 0 && mark.hasRange { TileLine(position: nil, length: len, mark: mark) }
        }
    }

    /// Star (top right), full screen (bottom left), bin (bottom right): 46dp touch, 34dp plate.
    private func corners(_ mark: ClipMark) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                cornerKey(action: {
                    var m = mark
                    m.star.toggle()
                    store.setMark(clip.name, m, label: mark.star ? "Star removed" : "Star")
                }) {
                    CineIcon(.star(filled: mark.star), size: small ? 16 : 20, color: mark.star ? Color.starAmber : Color.ivory)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                cornerKey(action: onOpen) { CineIcon(.expand, size: small ? 14 : 18) }
                Spacer(minLength: 0)
                cornerKey(action: { if mark.star { refused = true } else { delete() } }) {
                    CineIcon(.trash, size: 18 * (small ? 0.7 : 0.85), color: mark.star ? Color.faint : Color.ivory)
                }
            }
        }
        .padding(s(2))
    }

    private func cornerKey<C: View>(action: @escaping () -> Void, @ViewBuilder _ icon: () -> C) -> some View {
        Button(action: action) {
            ZStack { icon() }
                .frame(width: s(small ? 28 : 34), height: s(small ? 28 : 34))
                .background(Circle().fill(Color.plate))
                .frame(width: s(small ? 36 : 46), height: s(small ? 36 : 46))
                .contentShape(Circle())
        }
        .buttonStyle(CinePressStyle())
    }

    /// Shrinks and fades, then to the bin (the others slide up).
    private func delete() {
        ctl?.stop()
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) { k = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
            store.trash(clip)
            // Still there (the move failed): back.
            if store.clips.contains(where: { $0.name == clip.name }) { k = 1 }
        }
    }

    private func syncPlayer() {
        if live {
            if ctl == nil {
                let c = TilePlayer()
                c.load(clip.url, mark: store.mark(clip.name), muted: !sound)
                ctl = c
            }
        } else if let c = ctl {
            c.stop()
            ctl = nil
        }
    }

    /// Drag sideways on a playing tile: scrub (the tile's width = the whole clip).
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                if scrubSideways == nil { scrubSideways = abs(v.translation.width) > abs(v.translation.height) }
                guard scrubSideways == true, let c = ctl, c.duration > 0 else { return }
                if scrub == nil {
                    scrub = (c.position, c.playing)
                    c.pause()
                    c.dragging = true
                }
                c.seek((scrub?.from ?? 0) + Double(v.translation.width / max(width, 1)) * c.duration, exact: false)
            }
            .onEnded { _ in
                if let sc = scrub, let c = ctl {
                    c.dragging = false
                    c.seek(c.position, exact: true)
                    if sc.wasPlaying { c.play() }
                }
                scrub = nil
                scrubSideways = nil
            }
    }
}

/// The length chip, top left: 13sp (11 small), Plate capsule, padding 8x2, 6dp in.
private struct TileChip: View {
    let text: String
    let small: Bool
    private let s = CineScale.player
    var body: some View {
        Text(text).font(s.font(small ? 11 : 13)).monospacedDigit().foregroundStyle(Color.ivory)
            .padding(.horizontal, s(8)).padding(.vertical, s(2))
            .background(Capsule().fill(Color.plate))
            .padding(s(6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

/// The 4dp line along the bottom: where it is (Brass, while playing) and the in / out part (green).
private struct TileLine: View {
    let position: Double?
    let length: Double
    let mark: ClipMark
    private let s = CineScale.player
    var body: some View {
        Canvas { ctx, size in
            guard length > 0 else { return }
            if let p = position {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * CGFloat(min(p / length, 1)), height: size.height)), with: .color(Color.brass))
            }
            if mark.hasRange {
                let a = size.width * CGFloat(mark.inS / length)
                let b = size.width * CGFloat(min(mark.outS, length) / length)
                ctx.fill(Path(CGRect(x: a, y: 0, width: max(b - a, 0), height: size.height)), with: .color(Color.okGreen))
            }
        }
        .frame(height: s(4))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

/// The clip playing in its tile, round and round (only its in / out part, if set).
private struct TileLive: View {
    @ObservedObject var ctl: TilePlayer
    let mark: ClipMark
    let length: Double
    let small: Bool
    let tiny: Bool
    var body: some View {
        let dur = ctl.duration > 0 ? ctl.duration : length
        ZStack {
            PlayerLayerView(player: ctl.player, gravity: .resizeAspectFill)
            TileChip(text: ctl.duration > 0 ? "\(clipClock(ctl.position)) / \(clipClock(ctl.duration))" : clipClock(length), small: small)
            TileLine(position: ctl.position, length: dur, mark: mark)
        }
    }
}

/// One tile's AVPlayer: loops (the in / out part if set), muted unless it's the tapped one with sound.
final class TilePlayer: ObservableObject {
    let player = AVPlayer()
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var playing = false
    /// A finger is scrubbing: playback doesn't move the position meanwhile.
    var dragging = false
    var mark = ClipMark()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(_ url: URL, mark: ClipMark, muted: Bool) {
        self.mark = mark
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        setMuted(muted)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 6, timescale: 100), queue: .main) { [weak self] t in
            self?.tick(t)
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.player.seek(to: CMTime(seconds: self.mark.hasRange ? self.mark.inS : 0, preferredTimescale: 600))
            self.player.play()
        }
        if mark.hasRange { player.seek(to: CMTime(seconds: mark.inS, preferredTimescale: 600)) }
        player.play()
        playing = true
    }

    private func tick(_ t: CMTime) {
        if let d = player.currentItem?.duration, d.isNumeric, d.seconds > 0, abs(d.seconds - duration) > 0.001 { duration = d.seconds }
        guard t.isNumeric else { return }
        let pos = t.seconds
        if !dragging { position = pos }
        if mark.hasRange && playing && !dragging && (pos >= mark.outS || pos < mark.inS - 0.3) {
            player.seek(to: CMTime(seconds: mark.inS, preferredTimescale: 600))
        }
    }

    func setMuted(_ m: Bool) {
        player.isMuted = m
        if !m {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    func toggle() { if playing { pause() } else { play() } }
    func play() { player.play(); playing = true }
    func pause() { player.pause(); playing = false }

    func seek(_ t: Double, exact: Bool) {
        position = min(max(t, 0), duration)
        let tol: CMTime = exact ? .zero : .positiveInfinity
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
    }

    func stop() {
        player.pause()
        playing = false
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        player.replaceCurrentItem(with: nil)
    }

    deinit { stop() }
}

// MARK: - shared pieces (also used by Player.swift and Backup.swift)

extension Color {
    /// Old names, kept for anyone still using them: Android's StarAmber and Green (Theme.swift).
    static let libStar = Color(argb: 0xFFE8A93C)
    static let libGreen = Color(argb: 0xFF3FBF5F)
}

/// A made-up picture for sample tiles (simulator screenshots): sky, sun, ground.
struct LibFakeFrame: View {
    let hue: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.6),
                                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.25)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.25, brightness: 1).opacity(0.55))
                .frame(width: h * 0.28, height: h * 0.28)
                .position(x: w * 0.68, y: h * 0.36)
            Rectangle().fill(Color(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.4, brightness: 0.14))
                .frame(width: w, height: h * 0.34)
                .position(x: w / 2, y: h * 0.83)
        }
    }
}

/// 0:42, 12:05, 1:02:03.
func clipClock(_ s: Double) -> String {
    let t = Int(s.isFinite ? max(0, s) : 0)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

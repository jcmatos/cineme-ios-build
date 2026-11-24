import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Settings, drawn like the Android app's settings panel (CameraScreen.kt:1786-2255): a 124dp nav
// column on #141210 (in portrait a row along the top), the page name in Brass, a Close pill, and rows
// with the label left and text-only options right. All at the settings scale (x1.04).

/// The settings pages, in the nav's order (Android's order, with the iPhone's own pages in between).
enum SettingsPage: String, CaseIterable, Identifiable {
    case video = "Video"
    /// Android's second page (Sharpening, Stabilization): here Stabilization.
    case image = "Image"
    case auto = "Auto"
    case photo = "Photo"
    case saveTo = "Save to"
    case screen = "Screen"
    case exposure = "Exposure"
    case focus = "Focus"
    case sound = "Sound"
    case timecode = "Timecode"
    case anamorphic = "Anamorphic"
    case backup = "Backup"
    case tracking = "Tracking"
    case gimbal = "Gimbal"
    case remote = "Remote"
    case formats = "Formats"
    /// Not a page: opens the full-screen Help (HelpPanel), as on Android.
    case help = "Help"

    var id: String { rawValue }
    var title: String { rawValue }
    /// The pages in the nav (Help comes last, on its own).
    static var pages: [SettingsPage] { allCases.filter { $0 != .help } }
}

/// Which page was open, kept while the app runs (Android's SettingsMemory).
enum SettingsPaneMemory {
    static var page: SettingsPage = .video
}

/// The settings panel. Fills what it is given: landscape = nav column left, portrait (taller than
/// wide) = nav row on top. The caller places it (left 62% in landscape, bottom 60% in portrait) and
/// closes it on a tap outside.
struct SettingsPanel: View {
    @ObservedObject var camera: Camera
    @ObservedObject var gimbal: Gimbal
    var page: SettingsPage? = nil
    let onClose: () -> Void

    @State private var current: SettingsPage
    @State private var showHelp = false
    @State private var showGimbal = false
    private let s = CineScale.settings

    init(camera: Camera, gimbal: Gimbal, page: SettingsPage? = nil, onClose: @escaping () -> Void) {
        self.camera = camera
        self.gimbal = gimbal
        self.page = page
        self.onClose = onClose
        let start = page ?? SettingsPaneMemory.page
        _current = State(initialValue: start == .help ? SettingsPaneMemory.page : start)
    }

    var body: some View {
        GeometryReader { g in
            let portrait = g.size.height > g.size.width
            // Where the panel reaches under the Dynamic Island / home indicator (when the caller lets
            // it fill the whole screen): the backgrounds go there, the content stays out.
            let safe = PaneSafeArea.overlap(g.frame(in: .global))
            if portrait {
                VStack(spacing: 0) {
                    navRow(safe)
                    pageBody(EdgeInsets(top: 0, leading: safe.leading, bottom: safe.bottom, trailing: safe.trailing))
                }
            } else {
                HStack(spacing: 0) {
                    navColumn(safe)
                    pageBody(EdgeInsets(top: safe.top, leading: 0, bottom: 0, trailing: safe.trailing))
                }
            }
        }
        .background(Color.sheet.ignoresSafeArea().onTapGesture {})
        .cineScale(.settings)
        .cineDefaultText(.settings)
        .onAppear { if page == .help { openHelp() } }
        .onChange(of: current) { _, p in SettingsPaneMemory.page = p }
        // What the clips are recorded as: the camera is set up again on every change.
        .onChange(of: camera.resolution) { _, _ in camera.reconfigure() }
        .onChange(of: camera.fps) { _, _ in camera.reconfigure() }
        .onChange(of: camera.look) { _, _ in camera.reconfigure() }
        .onChange(of: camera.codec) { _, c in
            if !c.allows(camera.look) { camera.look = .sdr }
            camera.reconfigure()
        }
        .onChange(of: camera.stabilization) { _, _ in camera.reconfigure() }
        .fullScreenCover(isPresented: $showHelp) { HelpPanel { showHelp = false } }
        .fullScreenCover(isPresented: $showGimbal) { GimbalPanel(gimbal: gimbal) { showGimbal = false } }
    }

    private func openHelp() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showHelp = true }
    }

    private func openGimbal() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showGimbal = true }
    }

    // MARK: nav

    /// Landscape: 124dp column, "Settings" Dim, one item per page, Help last in Dim.
    private func navColumn(_ safe: EdgeInsets) -> some View {
        PaneScroll {
            VStack(alignment: .leading, spacing: s(4)) {
                Text("Settings").font(s.font(15)).foregroundStyle(Color.dim)
                    .padding(.leading, s(8)).padding(.bottom, s(6))
                ForEach(SettingsPage.pages) { p in
                    PaneNavItem(name: p.title, on: current == p, fill: true) { current = p }
                }
                Spacer().frame(height: s(8))
                PaneNavItem(name: "Help", on: false, fill: true, help: true) { openHelp() }
            }
            .padding(.leading, s(8)).padding(.trailing, s(14)).padding(.vertical, s(14))
        }
        .frame(width: s(124))
        .frame(maxHeight: .infinity)
        .padding(.leading, safe.leading)
        .padding(.top, safe.top)
        .background(Color.navColumn.ignoresSafeArea())
    }

    /// Portrait: a row along the top that scrolls sideways to the open page.
    private func navRow(_ safe: EdgeInsets) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: s(2)) {
                    ForEach(SettingsPage.pages) { p in
                        PaneNavItem(name: p.title, on: current == p, fill: false) { current = p }.id(p)
                    }
                    PaneNavItem(name: "Help", on: false, fill: false, help: true) { openHelp() }
                }
                .padding(.horizontal, s(8)).padding(.vertical, s(6))
            }
            .scrollIndicators(.hidden)
            .padding(.leading, safe.leading).padding(.trailing, safe.trailing).padding(.top, safe.top)
            .background(Color.navColumn)
            .onAppear { proxy.scrollTo(current, anchor: UnitPoint(x: 0.15, y: 0.5)) }
            .onChange(of: current) { _, p in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(p, anchor: UnitPoint(x: 0.15, y: 0.5)) }
            }
        }
    }

    // MARK: page

    private func pageBody(_ safe: EdgeInsets) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(current.title).font(s.font(22, .medium)).foregroundStyle(Color.brass)
                Spacer(minLength: s(8))
                CinePill("Close", action: onClose)
            }
            Spacer().frame(height: s(4))
            PaneScroll {
                VStack(alignment: .leading, spacing: 0) {
                    pageContent
                        .disabled(camera.recording)
                    Spacer().frame(height: s(30))
                }
                .padding(.top, s(6))
                .padding(.trailing, s(14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(current)
        }
        .padding(.horizontal, s(20))
        .padding(.vertical, s(14))
        .padding(safe)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch current {
        case .video: VideoPage(camera: camera)
        case .image: ImagePage(camera: camera)
        case .auto: AutoPage(camera: camera)
        case .photo: PhotoSettingsSection(camera: camera)
        case .saveTo: SaveToPage(camera: camera)
        case .screen: ScreenPage(aids: .shared)
        case .exposure: ExposureSection(maps: .shared, codec: camera.codec)
        case .focus: FocusPage(aids: .shared, codec: camera.codec)
        case .sound:
            SoundModeSection(pro: .shared, onChange: { camera.applySound() })
            SoundSection(meter: .shared)
        case .timecode: TimecodeSection(pro: .shared, fps: camera.fps)
        case .anamorphic: AnamorphicSection(pro: .shared)
        case .backup: BackupView()
        case .tracking: TrackSettingsSection(tracker: Rig.shared.tracker)
        case .gimbal: GimbalSettingsPage(gimbal: gimbal) { openGimbal() }
        case .remote: RemoteSettingsContent()
        case .formats: FormatsPage(camera: camera)
        case .help: EmptyView()
        }
    }
}

/// One page button in the nav (NavItem :2158): 15sp, r10, padding 10x9; open = Brass fill, dark
/// text w600; others Ivory (Help Dim).
struct PaneNavItem: View {
    @Environment(\.cineScale) private var s
    let name: String
    let on: Bool
    var fill = false
    var help = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(s.font(15, on ? .semibold : .regular))
                .foregroundStyle(on ? Color.navSelectedText : (help ? Color.dim : Color.ivory))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, s(10)).padding(.vertical, s(9))
                .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
                .background(on ? Color.brass : Color.clear, in: cineRect(s(10)))
                .contentShape(cineRect(s(10)))
        }
        .buttonStyle(CinePressStyle())
    }
}

/// How far a view reaches into the window's safe area (Dynamic Island, home indicator), from its
/// global frame. Zero when the caller already keeps it inside the safe area.
/// Android draws from the screen edge; like the camera screen (CameraScreen.swift `side` / `grow`),
/// the panels use only part of the margins: 55% of the landscape side insets (still clear of the
/// Dynamic Island) and half of the home indicator's. The status bar / island on top stays whole.
enum PaneSafeArea {
    static let sideShare: CGFloat = 0.55
    static let bottomShare: CGFloat = 0.5

    @MainActor
    static func overlap(_ frame: CGRect) -> EdgeInsets {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard let w = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return EdgeInsets() }
        let i = w.safeAreaInsets
        let b = w.bounds
        let left = i.left * sideShare
        let right = i.right * sideShare
        let bottom = i.bottom * bottomShare
        return EdgeInsets(top: max(0, i.top - frame.minY),
                          leading: max(0, left - frame.minX),
                          bottom: max(0, frame.maxY - (b.height - bottom)),
                          trailing: max(0, frame.maxX - (b.width - right)))
    }
}

/// Arrow glyphs (▲ ▼ ◀ ▶ ●) at Android's size. Jost has none; iOS's fallback draws them about 1.5x as
/// big as Android's does, so they are set at 0.66 of the text size (remote rows RemoteSettings.kt:116,
/// the gimbal sheet's Pan / Tilt keys CameraScreen.kt:2302).
struct PaneArrow: View {
    @Environment(\.cineScale) private var s
    let glyph: String
    var sp: CGFloat = 15

    init(_ glyph: String, sp: CGFloat = 15) {
        self.glyph = glyph
        self.sp = sp
    }

    var body: some View {
        Text(glyph).font(s.font(sp * 0.66))
    }
}

// MARK: - old entry points (until CameraScreen uses SettingsPanel / GimbalPanel)

/// The panel in a sheet, with the app's gimbal. Kept so the old `.sheet { SettingsSheet(camera:) }` builds.
struct SettingsSheet: View {
    @ObservedObject var camera: Camera
    var page: SettingsPage? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let g = Rig.shared.tracker.gimbal {
            SettingsPanel(camera: camera, gimbal: g, page: page) { dismiss() }
        } else {
            Color.sheet.ignoresSafeArea().onAppear { dismiss() }
        }
    }
}

/// A single page on its own (sheets kept for old callers): title, Close, the page scrolling.
struct SettingsPageSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    private let s = CineScale.settings

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title).font(s.font(22, .medium)).foregroundStyle(Color.brass)
                Spacer(minLength: s(8))
                CinePill("Close") { dismiss() }
            }
            Spacer().frame(height: s(4))
            PaneScroll {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                    Spacer().frame(height: s(30))
                }
                .padding(.top, s(6)).padding(.trailing, s(14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, s(20)).padding(.vertical, s(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.sheet.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .cineScale(.settings)
        .cineDefaultText(.settings)
    }
}

// MARK: - pages

/// Settings > Video: what the clips are recorded as.
private struct VideoPage: View {
    @ObservedObject var camera: Camera

    var body: some View {
        PaneOpt("Resolution", Resolution.allCases, camera.resolution, title: { $0.rawValue }) { camera.resolution = $0 }
        PaneOpt("Frame rate", frameRates, camera.fps, title: { "\($0)" }) { camera.fps = $0 }
        PaneOpt("Codec", Codec.allCases, camera.codec, title: { $0.rawValue }) { camera.codec = $0 }
        if !camera.codec.isRAW {
            PaneOpt("Colour", Look.allCases.filter { camera.codec.allows($0) }, camera.look, title: { $0.rawValue }) { camera.look = $0 }
        }
        PaneRecordSignal()
        CineNote(note)
    }

    private var note: String {
        if let p = camera.problem { return p }
        var s = "Now: \(camera.formatText)."
        if camera.codec.isProRes { s += " ProRes files are large (4K30 422 HQ about 6 GB a minute; ProRes RAW over 10 GB)." }
        if camera.look == .log2 || camera.look == .log { s += " Log looks flat: grade it, or use Apple's LUT." }
        if camera.fps >= 100 { s += " 100 and 120 fps: Fusion Main (1x) only." }
        return s
    }
}

/// Settings > Image (Android Group("Image") :1868, Stabilization row; the iPhone has no sharpening switch).
private struct ImagePage: View {
    @ObservedObject var camera: Camera

    var body: some View {
        PaneOpt("Stabilization", [true, false], camera.stabilization, title: { $0 ? "Cinematic" : "Off" }) { camera.stabilization = $0 }
    }
}

/// Record signal (Beeper.swift's setting, as an Android Opt row): a sample on every change.
private struct PaneRecordSignal: View {
    var body: some View { RecordSignalPicker() }
}

/// The place in clips and photos (Locator.swift's setting, as an On / Off row). On asks for permission.
private struct PanePlaceRow: View {
    var body: some View { LocationToggle() }
}

/// Settings > Auto: where Auto aims (Android's AutoBias slider).
private struct AutoPage: View {
    @ObservedObject var camera: Camera

    var body: some View {
        PaneSliderRow("Brightness", value: $camera.autoBias, range: -10...10, low: "Darker", high: "Brighter",
                      shown: camera.autoBias > 0 ? "+\(camera.autoBias)" : "\(camera.autoBias)")
        CineNote("Where Auto (and Auto once from the gimbal) sets the light. 0 is normal, each step is 0.2 stop" +
                 (camera.autoBias == 0 ? "." : String(format: " (now %+.1f stop).", Double(camera.autoBias) * 0.2)))
    }
}

/// Settings > Save to: this iPhone or a USB-C drive, the copy in Photos, the place, the take log.
private struct SaveToPage: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera
    @AppStorage("toPhotos") private var toPhotos = true
    @State private var pickFolder = false

    var body: some View {
        PaneValueRow("Record to", camera.externalName ?? "This iPhone")
        PaneOnOff("Copy to Photos", isOn: $toPhotos)
        PanePlaceRow()
        FlowRow(spacing: s(6), lineSpacing: s(6)) {
            CinePill("Choose a folder on a USB-C drive") { pickFolder = true }
            if camera.externalName != nil {
                CinePill("Record to this iPhone again") { camera.setExternal(nil) }
            }
            ShareLink(item: RecLog.file) { PanePillLabel("Send the take log") }
                .buttonStyle(CinePressStyle())
        }
        .padding(.top, s(6))
        CineNote("On the iPhone the clips stay in the app (video manager, and Files > On My iPhone > CineMe) and a copy goes to Photos; turn that off to save space. Photos doesn't take ProRes RAW. ProRes at 4K 120 fps only records to a drive.")
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { camera.setExternal(url) }
            }
    }
}

/// Settings > Screen: vibrate on taps, histogram, framing guides.
private struct ScreenPage: View {
    @ObservedObject var aids: PictureAids
    @AppStorage("showGrid") private var grid = false
    @AppStorage("spiral") private var spiral = 0
    @AppStorage("haptics") private var haptics = true
    @AppStorage("hapticStrength") private var hapticStrength = 2

    var body: some View {
        PaneOnOff("Vibrate on taps", isOn: $haptics)
        PaneSliderRow("Vibration strength", value: $hapticStrength, range: 1...5, low: "Soft", high: "Firm", enabled: haptics)
            .onChange(of: hapticStrength) { _, _ in Haptics.tap(force: true) }
        PaneOnOff("Histogram", isOn: $aids.histogram)
        CineNote("Tap the histogram for the RGB parade, then the waveform. Red edge = blown highlights.")
        PaneOnOff("Grid (thirds)", isOn: $grid)
        PaneOpt("Golden spiral", SpiralCorner.allCases, SpiralCorner(rawValue: spiral) ?? .off, title: { $0.label }) { spiral = $0.rawValue }
        if spiral != SpiralCorner.off.rawValue {
            CineNote("The arrow is the corner the spiral starts from (its wide curve).")
        }
    }
}

/// Settings > Focus: peaking and the sharp areas.
private struct FocusPage: View {
    @ObservedObject var aids: PictureAids
    let codec: Codec

    var body: some View {
        PaneOnOff("Focus peaking", isOn: $aids.peaking)
        PaneSliderRow("Peaking sensitivity", value: $aids.peakSens, range: 1...5, low: "Less", high: "More", enabled: aids.peaking)
        PaneSliderRow("Peaking colour", value: $aids.peakAlpha, range: 1...5, low: "Faint", high: "Strong", enabled: aids.peaking)
        CineNote("Peaking marks in red the edges that are in focus.")
        PaneOnOff("Show sharp areas (AF)", isOn: $aids.zones)
        CineNote("Small green brackets where the picture is sharp, in AF. MF: the round arrow by the focus slider opens the focus ring." +
                 (codec.isProRes ? " Histogram, peaking and sharp areas are off with ProRes." : " Not with ProRes."))
    }
}

/// Settings > Formats: what the lens really has.
private struct FormatsPage: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var camera: Camera

    var body: some View {
        CineNote("The formats of the \(camera.lens.label) camera, as it reports them.")
        ForEach(Array(camera.formatsList.enumerated()), id: \.offset) { _, f in
            Text(f).font(.system(size: s(12), design: .monospaced)).foregroundStyle(Color.logText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s(4))
        }
    }
}

// MARK: - rows (Android Opt, SliderRow, LabelRow, status rows), shared by the settings pages

/// Android `Opt` (:2196): label left (Ivory 15sp), the options right in a flowing row spaced 14dp
/// (7dp for 0..10 scales); the chosen one Ivory w500 with the brass mark, the others Faint. Label above
/// when it doesn't fit beside them. Whole row 0.4 alpha when disabled.
struct PaneOpt<T: Hashable>: View {
    @Environment(\.cineScale) private var s
    let label: String
    let options: [T]
    let chosen: T
    var enabled = true
    var spacing: CGFloat = 14
    let title: (T) -> String
    let onPick: (T) -> Void

    init(_ label: String, _ options: [T], _ chosen: T, enabled: Bool = true, spacing: CGFloat = 14,
         title: @escaping (T) -> String, onPick: @escaping (T) -> Void) {
        self.label = label
        self.options = options
        self.chosen = chosen
        self.enabled = enabled
        self.spacing = spacing
        self.title = title
        self.onPick = onPick
    }

    var body: some View {
        PaneLabelRow {
            Text(label).font(s.font(15)).foregroundStyle(Color.ivory)
        } controls: {
            FlowRow(spacing: s(spacing), lineSpacing: s(6)) {
                ForEach(options, id: \.self) { o in
                    CineOption(title(o), selected: o == chosen, enabled: enabled) { if o != chosen { onPick(o) } }
                }
            }
        }
        .padding(.vertical, s(5))
        .opacity(enabled ? 1 : Theme.disabledAlpha)
    }
}

/// An On / Off setting (Android: Opt with "On", "Off").
struct PaneOnOff: View {
    let label: String
    @Binding var isOn: Bool
    var enabled = true

    init(_ label: String, isOn: Binding<Bool>, enabled: Bool = true) {
        self.label = label
        self._isOn = isOn
        self.enabled = enabled
    }

    var body: some View {
        PaneOpt(label, [true, false], isOn, enabled: enabled, title: { $0 ? "On" : "Off" }) { isOn = $0 }
    }
}

/// "Status   Connected": label left, value right (Dim unless told), 4dp padding (Android :2004).
struct PaneValueRow: View {
    @Environment(\.cineScale) private var s
    let label: String
    let value: String
    var color: Color = Color.dim

    init(_ label: String, _ value: String, color: Color = Color.dim) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: s(12)) {
            Text(label).font(s.font(15)).foregroundStyle(Color.ivory)
            Spacer(minLength: 0)
            Text(value).font(s.font(15)).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, s(4))
    }
}

/// The look of a CinePill for things that are not a plain Button (ShareLink).
struct PanePillLabel: View {
    @Environment(\.cineScale) private var s
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(s.font(15)).foregroundStyle(Color.ivory)
            .padding(.horizontal, s(13)).padding(.vertical, s(7))
            .plateCapsule()
    }
}

/// Android `LabelRow` (:2165): the label left and the controls right when the label fits beside
/// them (in up to two lines), else the label above (4dp) and the controls under it, wrapping at the
/// full width. (Theme's CineLabelRow measures the controls unwrapped, so a long option list that
/// wraps overlaps the next row; this one measures them at the row's width.)
struct PaneLabelRow<Label: View, Controls: View>: View {
    @Environment(\.cineScale) private var s
    var twoLines = true
    @ViewBuilder let label: () -> Label
    @ViewBuilder let controls: () -> Controls

    init(twoLines: Bool = true, @ViewBuilder label: @escaping () -> Label, @ViewBuilder controls: @escaping () -> Controls) {
        self.twoLines = twoLines
        self.label = label
        self.controls = controls
    }

    var body: some View {
        PaneLabelRowLayout(gap: s(12), top: s(4), twoLines: twoLines) {
            label()
            controls()
        }
    }
}

struct PaneLabelRowLayout: Layout {
    let gap: CGFloat
    let top: CGFloat
    let twoLines: Bool

    private struct Plan {
        var side: Bool
        var label: CGSize
        var ctrl: CGSize
    }

    private func plan(_ width: CGFloat, _ v: Subviews) -> Plan {
        let w: CGFloat? = width.isFinite ? width : nil
        // Beside the label only when the controls fit unwrapped (a wrapped list goes under the label).
        let single = v[1].sizeThatFits(.unspecified)
        let ctrl = v[1].sizeThatFits(ProposedViewSize(width: w, height: nil))
        let one = v[0].sizeThatFits(.unspecified)
        let room = width - ctrl.width - gap
        if room > 0, ctrl.height <= single.height + 0.5 {
            if one.width <= room { return Plan(side: true, label: one, ctrl: ctrl) }
            if twoLines, room >= one.width * 0.55 {   // not so narrow that a word breaks
                let wrapped = v[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
                if wrapped.width <= room + 0.5, wrapped.height <= one.height * 2 + 1 {
                    return Plan(side: true, label: wrapped, ctrl: ctrl)
                }
            }
        }
        let lab = v[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
        return Plan(side: false, label: lab, ctrl: ctrl)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? .infinity
        let p = plan(width, subviews)
        let w = width.isFinite ? width : (p.side ? p.label.width + gap + p.ctrl.width : max(p.label.width, p.ctrl.width))
        let h = p.side ? max(p.label.height, p.ctrl.height) : p.label.height + top + p.ctrl.height
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let p = plan(bounds.width, subviews)
        if p.side {
            let h = bounds.height
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (h - p.label.height) / 2), proposal: ProposedViewSize(p.label))
            subviews[1].place(at: CGPoint(x: bounds.maxX - p.ctrl.width, y: bounds.minY + (h - p.ctrl.height) / 2),
                              proposal: ProposedViewSize(p.ctrl))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(p.label))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + p.label.height + top),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// Android `SliderRow` (:2134): label (beside only if it fits on one line, else above), low word
/// Faint 12sp right-aligned in 56dp, the slider 130dp, high word Faint 12sp, the value Ivory in 40dp.
struct PaneSliderRow: View {
    @Environment(\.cineScale) private var s
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let low: String
    let high: String
    var shown: String? = nil
    var enabled = true

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, low: String, high: String,
         shown: String? = nil, enabled: Bool = true) {
        self.label = label
        self._value = value
        self.range = range
        self.low = low
        self.high = high
        self.shown = shown
        self.enabled = enabled
    }

    var body: some View {
        PaneLabelRow(twoLines: false) {
            Text(label).font(s.font(15)).foregroundStyle(Color.ivory)
        } controls: {
            HStack(spacing: 0) {
                Text(low).font(s.font(12)).foregroundStyle(Color.faint).lineLimit(1)
                    .frame(minWidth: s(56), alignment: .trailing)
                // Material's Slider is 48dp tall (minimum touch size), its thumb 44.
                PaneSlider(value: $value, range: range, enabled: enabled)
                    .frame(width: s(118), height: s(48))
                    .padding(.horizontal, s(6))
                Text(high).font(s.font(12)).foregroundStyle(Color.faint).lineLimit(1)
                Text(shown ?? "\(value)").font(s.font(15)).foregroundStyle(Color.ivory).lineLimit(1)
                    .frame(width: s(40), alignment: .trailing)
            }
            .fixedSize()
        }
        .padding(.vertical, s(2))
        .opacity(enabled ? 1 : Theme.disabledAlpha)
    }
}

/// Material 3 slider as Android draws it: 16dp track (Brass before the thumb, Edge after, 6dp gap
/// each side of the thumb, 2dp inner corners), a 4x44dp Ivory bar thumb, a 4dp Brass stop dot at the
/// end. Whole steps; drag or tap anywhere on it.
struct PaneSlider: View {
    @Environment(\.cineScale) private var s
    @Binding var value: Int
    let range: ClosedRange<Int>
    var enabled = true

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            let span = CGFloat(max(1, range.upperBound - range.lowerBound))
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let frac = CGFloat(clamped - range.lowerBound) / span
            let tw = s(4)
            let gap = s(6)
            let th = s(16)
            let x = min(max(frac * w, tw / 2), w - tw / 2)
            let activeW = x - tw / 2 - gap
            let restX = x + tw / 2 + gap
            let restW = w - restX
            ZStack(alignment: .topLeading) {
                if activeW > 0 {
                    paneTrackPiece(width: activeW, height: th, left: th / 2, right: s(2))
                        .fill(Color.brass)
                        .frame(width: activeW, height: th)
                        .offset(y: (h - th) / 2)
                }
                if restW > 0 {
                    paneTrackPiece(width: restW, height: th, left: s(2), right: th / 2)
                        .fill(Color.edge)
                        .frame(width: restW, height: th)
                        .offset(x: restX, y: (h - th) / 2)
                    if restW > th {
                        Circle().fill(Color.brass)
                            .frame(width: s(4), height: s(4))
                            .offset(x: w - th / 2 - s(2), y: h / 2 - s(2))
                    }
                }
                Capsule().fill(Color.ivory)
                    .frame(width: tw, height: min(h, s(44)))
                    .offset(x: x - tw / 2, y: max(0, h - s(44)) / 2)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        let f = min(max(d.location.x / max(w, 1), 0), 1)
                        let v = range.lowerBound + Int((f * span).rounded())
                        if v != value { value = v }
                    }
            )
        }
        .allowsHitTesting(enabled)
    }
}

/// One piece of the slider track: `left` / `right` corner radii (clamped to the piece).
private func paneTrackPiece(width: CGFloat, height: CGFloat, left: CGFloat, right: CGFloat) -> UnevenRoundedRectangle {
    let l = min(left, width / 2, height / 2)
    let r = min(right, width / 2, height / 2)
    return UnevenRoundedRectangle(topLeadingRadius: l, bottomLeadingRadius: l, bottomTrailingRadius: r, topTrailingRadius: r,
                                  style: .circular)
}

/// A vertical scroll with Android's thin scroll bar (:2084): 3dp wide, 1dp from the right edge,
/// #66EFE8DC, r2dp, at least 24dp tall; only when there is something to scroll.
struct PaneScroll<Content: View>: View {
    @Environment(\.cineScale) private var s
    @ViewBuilder let content: () -> Content
    @State private var m = PaneScrollMetrics()

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        ScrollView(.vertical) { content() }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: PaneScrollMetrics.self) { g in
                PaneScrollMetrics(offset: g.contentOffset.y + g.contentInsets.top,
                                  content: g.contentSize.height, view: g.containerSize.height)
            } action: { _, n in
                m = n
            }
            .overlay(alignment: .topTrailing) { bar }
    }

    @ViewBuilder private var bar: some View {
        let view = m.view
        let scrollable = m.content - m.view
        if scrollable > 1, view > 0 {
            let h = max(view * view / (view + scrollable), s(24))
            let y = (view - h) * min(max(m.offset / scrollable, 0), 1)
            RoundedRectangle(cornerRadius: s(2), style: .circular)
                .fill(Color.scrollBar)
                .frame(width: s(3), height: h)
                .padding(.trailing, s(1))
                .offset(y: y)
                .allowsHitTesting(false)
        }
    }
}

struct PaneScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var view: CGFloat = 0
}

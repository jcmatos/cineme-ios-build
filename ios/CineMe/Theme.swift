import CoreText
import SwiftUI
import UIKit

// The Android app's look ("film body": ivory lettering on black, brass for what is selected, a red
// dot for record), so the iPhone app looks the same. Reference: DEVELOPMENT_FILES/android-ref/DESIGN.md
// (every token with its Kotlin file:line). API summary for the screens: THEME-API.md.
//
// Everything here takes Android numbers (dp / sp) and converts them with the area's scale (below),
// so a screen is written with the same numbers as the Kotlin: `s(52)`, `.font(s.font(15, .medium))`.

// MARK: - Scale

/// Android dp / sp -> iOS points.
///
/// Android draws the camera screen, the dialogs over it, the player and the library at 0.8x density
/// (CameraScreen.kt:169-172, PlayerActivity.kt:136), and the settings sheet at 0.8 x 1.3 = 1.04x
/// (CameraScreen.kt:1798-1801). dp and pt are both 1/160 inch units, so 1 dp ~ 1 pt to start with.
///
/// The reference screenshots are a Pixel 6: 411 x 914 dp. The iPhone 18 Pro is 402 x 874 pt, about the
/// same physical size. The UI is laid out against the short side (landscape height: "the screen is
/// only 360dp tall"), so the factor keeps the same proportion of the screen height as on the Pixel:
/// `device = 402 / 411 = 0.978`. Then camera / player / library = 0.8 x 0.978 = 0.782 pt per dp,
/// settings = 1.04 x 0.978 = 1.017 pt per dp. (The width is 874 / 914 = 0.956 of the Pixel's, so a
/// landscape row is ~2% roomier there than here; nothing on Android fills the full width.)
enum Theme {
    /// iPhone 18 Pro short side (pt) / Pixel 6 short side (dp).
    static let device: CGFloat = 402.0 / 411.0
    /// Camera screen, its dialogs (confirm, voice note, help, moves, time-lapse), focus ring, level pill.
    static let camScale: CGFloat = 0.8 * device
    /// Settings sheet (and Remote inside it).
    static let settingsScale: CGFloat = 1.04 * device
    /// Player and library (Android's PlayerActivity, its own 0.8x).
    static let playerScale: CGFloat = 0.8 * device

    /// Android dp/sp on the camera screen -> pt. `Theme.cam(52)` = 40.7 pt.
    static func cam(_ dp: CGFloat) -> CGFloat { dp * camScale }
    /// Android dp/sp in the settings sheet -> pt.
    static func settings(_ dp: CGFloat) -> CGFloat { dp * settingsScale }
    /// Android dp/sp in the player / library -> pt.
    static func player(_ dp: CGFloat) -> CGFloat { dp * playerScale }

    /// Compose `letterSpacing = 0.08.em` on a `sp`-sized text -> SwiftUI `.tracking(_:)` points.
    static func tracking(_ em: CGFloat, sp: CGFloat, scale: CGFloat = camScale) -> CGFloat { em * sp * scale }

    /// Press look: Android dims a disabled control to this.
    static let disabledAlpha: Double = 0.4
}

/// The scale of the area a view is in: shared views (pills, keys, icons, dialogs) read it from the
/// environment, as the Compose code reads LocalDensity. Default = camera. The settings sheet sets
/// `.cineScale(.settings)`, the player / library `.cineScale(.player)`.
///
///     @Environment(\.cineScale) private var s
///     Text("Close").font(s.font(15)).padding(.horizontal, s(13))
struct CineScale: Equatable {
    var factor: CGFloat
    static let cam = CineScale(factor: Theme.camScale)
    static let settings = CineScale(factor: Theme.settingsScale)
    static let player = CineScale(factor: Theme.playerScale)

    /// Android dp -> pt.
    func callAsFunction(_ dp: CGFloat) -> CGFloat { dp * factor }
    /// Jost at an Android sp size.
    func font(_ sp: CGFloat, _ weight: Font.Weight = .regular) -> Font { .jost(sp * factor, weight) }
    /// Compose letterSpacing in em, for a text of `sp`.
    func tracking(_ em: CGFloat, sp: CGFloat) -> CGFloat { em * sp * factor }
}

private struct CineScaleKey: EnvironmentKey {
    static let defaultValue = CineScale.cam
}

extension EnvironmentValues {
    var cineScale: CineScale {
        get { self[CineScaleKey.self] }
        set { self[CineScaleKey.self] = newValue }
    }
}

extension View {
    /// The Android area this view is in (camera / settings / player): sets the scale shared views use.
    func cineScale(_ scale: CineScale) -> some View { environment(\.cineScale, scale) }

    /// Android's default text style: Jost 15sp Ivory (CameraScreen.kt:173, PlayerActivity.kt:137).
    func cineDefaultText(_ scale: CineScale = .cam) -> some View {
        font(scale.font(15)).foregroundStyle(Color.ivory)
    }
}

// MARK: - Font: Jost

/// Jost, the Android app's only typeface (app/src/main/res/font/jost.ttf, here Fonts/Jost.ttf, listed
/// in Info.plist UIAppFonts). One variable font, axis `wght` 100..900 (default 400).
/// PostScript name "Jost-Regular" (family "Jost"). The weight is set on the `wght` axis through
/// kCTFontVariationAttribute, so 300 / 500 / 600 / 700 are the real designs (as Android's
/// FontVariation.weight), not synthesised bold.
enum Jost {
    static let postScriptName = "Jost-Regular"
    /// 'wght' as the four-char-code number Core Text wants for the axis key.
    private static let wghtAxis = NSNumber(value: 0x7767_6874)
    private static let cache = NSCache<NSString, UIFont>()

    /// True when the font file was found and registered (else the system font stands in).
    static let isLoaded: Bool = UIFont(name: postScriptName, size: 12) != nil

    /// Jost at `size` points and weight `wght` (100...900).
    static func uiFont(_ size: CGFloat, wght: CGFloat = 400) -> UIFont {
        let w = min(max(wght, 100), 900)
        let key = "\(size)|\(w)" as NSString
        if let f = cache.object(forKey: key) { return f }
        let f: UIFont
        if isLoaded {
            let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            let d = UIFontDescriptor(fontAttributes: [
                .name: postScriptName,
                variation: [wghtAxis: NSNumber(value: Double(w))],
            ])
            f = UIFont(descriptor: d, size: size)
        } else {
            f = .systemFont(ofSize: size, weight: uiWeight(w))
        }
        cache.setObject(f, forKey: key)
        return f
    }

    /// SwiftUI weight -> the `wght` axis value (Compose FontWeight numbers).
    static func wght(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .ultraLight: return 200
        case .thin: return 100
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    private static func uiWeight(_ w: CGFloat) -> UIFont.Weight {
        switch w {
        case ..<150: return .thin
        case ..<250: return .ultraLight
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }
}

extension Font {
    /// Jost at `size` POINTS (already converted). Weight: .light 300, .regular 400, .medium 500,
    /// .semibold 600, .bold 700 (Android FontWeight(300...700)).
    static func jost(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(Jost.uiFont(size, wght: Jost.wght(weight)) as CTFont)
    }

    /// Jost at `size` points and any axis weight 100...900 (Compose `FontWeight(n)`).
    static func jost(_ size: CGFloat, wght: CGFloat) -> Font {
        Font(Jost.uiFont(size, wght: wght) as CTFont)
    }

    /// Jost at an Android sp size on the camera screen (x0.782): `.font(.cam(15))`.
    static func cam(_ sp: CGFloat, _ weight: Font.Weight = .regular) -> Font { .jost(Theme.cam(sp), weight) }
    /// Jost at an Android sp size in the settings sheet (x1.017).
    static func settings(_ sp: CGFloat, _ weight: Font.Weight = .regular) -> Font { .jost(Theme.settings(sp), weight) }
    /// Jost at an Android sp size in the player / library (x0.782).
    static func player(_ sp: CGFloat, _ weight: Font.Weight = .regular) -> Font { .jost(Theme.player(sp), weight) }
}

// MARK: - Colours

extension Color {
    /// 0xAARRGGBB, as Compose's `Color(0xAARRGGBB)`.
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

// Declared on `ShapeStyle where Self == Color`, so both `Color.ivory` and `.foregroundStyle(.ivory)` /
// `.fill(.plate)` work. Android names in brackets where the Swift name differs.
extension ShapeStyle where Self == Color {
    // The palette (CameraScreen.kt:147-159).
    /// All primary text and icons.
    static var ivory: Color { Color(argb: 0xFFEDE6D6) }
    /// Secondary labels: drum titles, status numbers, notes.
    static var dim: Color { Color(argb: 0xFF8D877A) }
    /// Unselected options, far drum values.
    static var faint: Color { Color(argb: 0xFF6D685D) }
    /// Selected marks, active borders, section titles.
    static var brass: Color { Color(argb: 0xFFB8955A) }
    /// [Red] Record, index marks, alarms, Yes buttons. (Not `red`: SwiftUI has Color.red.)
    static var rec: Color { Color(argb: 0xFFD7261E) }
    /// Background of every floating pill / round button: black 66%.
    static var plate: Color { Color(argb: 0xA8000000) }
    /// Drum wheel face, log box, thumbnail placeholders.
    static var drum: Color { Color(argb: 0xFF151413) }
    /// 1dp borders of buttons, slider inactive track.
    static var edge: Color { Color(argb: 0xFF3A3833) }
    /// Settings / Help / dialog panels.
    static var sheet: Color { Color(argb: 0xFF0D0C0B) }
    /// [Live] Gimbal "G" badge when connected.
    static var live: Color { Color(argb: 0xFF7FA06A) }
    /// [Blue] Record colour while a gimbal move is armed.
    static var moveBlue: Color { Color(argb: 0xFF3D7FE0) }

    // More camera-screen colours.
    /// Drum values next to the current one (:1253).
    static var drumNear: Color { Color(argb: 0xFFA39C8C) }
    /// Record key inner well (:1366); blue-mode well below.
    static var recWell: Color { Color(argb: 0xFF2A1513) }
    static var recWellBlue: Color { Color(argb: 0xFF131C2A) }
    /// Shutter key body (:1355).
    static var shutterBody: Color { Color(argb: 0xFF1D1C1A) }
    /// Dialog scrim, confirm / voice note / marked (:1519, :1639, :1691, RollDialog.kt:215).
    static var scrim: Color { Color(argb: 0x99000000) }
    /// Darker scrim: moves / time-lapse dialogs, library sort popup (Library.kt:360, RollDialog.kt:116).
    static var scrimDark: Color { Color(argb: 0xAA000000) }
    /// Settings nav column (:1827, :1831).
    static var navColumn: Color { Color(argb: 0xFF141210) }
    /// Text of the selected nav item, on Brass (:2161).
    static var navSelectedText: Color { Color(argb: 0xFF1A1611) }
    /// Settings scroll bar (:2093).
    static var scrollBar: Color { Color(argb: 0x66EFE8DC) }
    /// Focus "wide" sharp-zone brackets (:621, :632).
    static var focusWide: Color { Color(argb: 0xFF8FD18F) }
    /// Arms trigger "waiting" dot (:565, :577).
    static var armsYellow: Color { Color(argb: 0xFFFFE9A8) }
    /// "Video saved" / "Photo saved" toast (:1061).
    static var toastSaved: Color { Color(argb: 0xFF1E8E3E) }
    /// "WITHOUT SOUND" toast (:1062).
    static var toastNoSound: Color { Color(argb: 0xFFC77700) }
    /// RGB parade (:867-869).
    static var paradeR: Color { Color(argb: 0xFFE0574E) }
    static var paradeG: Color { Color(argb: 0xFF6FC36A) }
    static var paradeB: Color { Color(argb: 0xFF5A8BE6) }
    /// Portrait histogram frame (:265).
    static var histogramFrame: Color { Color(argb: 0xFF55504A) }
    /// Gimbal log text, monospace 12sp (:2326).
    static var logText: Color { Color(argb: 0xFFCFC6B0) }

    // Secondary screens (DESIGN.md section 8).
    /// [StarAmber] Stars, an "on" library bar button, selected sort (Library.kt:75).
    static var starAmber: Color { Color(argb: 0xFFE8A93C) }
    /// [Green] Level OK, in / out, remote connected (Library.kt:76, LevelPill.kt:88).
    static var okGreen: Color { Color(argb: 0xFF3FBF5F) }
    /// Level 1..3 deg, time-lapse warning (LevelPill.kt:89, Timelapse.kt:133).
    static var levelYellow: Color { Color(argb: 0xFFE0B830) }
    /// Focus ring knurl ridge / marker ridge (FocusRing.kt:128).
    static var ringRidge: Color { Color(argb: 0xFF55524A) }
    static var ringMarker: Color { Color(argb: 0xFFE8C14A) }
    /// Framing guides: white 45% (FramingGuides.kt:14).
    static var guideLine: Color { Color(argb: 0x73FFFFFF) }
    /// Library portrait bars (Library.kt:340, 344).
    static var libraryBar: Color { Color(argb: 0xE0000000) }
    /// Library / player message capsule (Library.kt:352, PlayerActivity.kt:186).
    static var toastBack: Color { Color(argb: 0xF0202020) }
    /// Library sort popup card (Library.kt:361).
    static var sortCard: Color { Color(argb: 0xFF1A1917) }
    /// Library tile background (Library.kt:459).
    static var tile: Color { Color(argb: 0xFF151515) }
    /// Remote drawing: stand / face / buttons (RemoteSettings.kt:222, 225, 231).
    static var remoteStand: Color { Color(argb: 0xFF1C1C1C) }
    static var remoteFace: Color { Color(argb: 0xFF050505) }
    static var remoteButton: Color { Color(argb: 0xFFB9BCC0) }

    // The old-radio dialogs: gimbal moves, time-lapse (RollDialog.kt:65-69, Timelapse.kt).
    /// Panel gradient top -> bottom.
    static var walnut: Color { Color(argb: 0xFF2A1F16) }
    static var walnutDark: Color { Color(argb: 0xFF17110C) }
    /// [DialGlass] Cream dial window / result card.
    static var dialGlass: Color { Color(argb: 0xFFE9DFC6) }
    /// [DialInk] Dark brown ink on the cream.
    static var dialInk: Color { Color(argb: 0xFF3A2E22) }
    /// [Amber] Lit knob ticks, knob values, dial caption.
    static var amber: Color { Color(argb: 0xFFE8A93C) }
    /// Hint / caption text on walnut (RollDialog.kt:211, Timelapse.kt:144).
    static var walnutHint: Color { Color(argb: 0xFFB9A98C) }
    /// Dial sky (RollDialog.kt:301).
    static var dialSky: Color { Color(argb: 0x223A6EA5) }
    /// The live position on the dial (RollDialog.kt:335).
    static var liveMove: Color { Color(argb: 0xFF8C2A1E) }
    /// Knob (RollDialog.kt:447-466): unlit tick, shadow, body gradient, knurl, cap gradient.
    static var knobTick: Color { Color(argb: 0xFF6B5A44) }
    static var knobShadow: Color { Color(argb: 0x88000000) }
    static var knobBodyLight: Color { Color(argb: 0xFF4A3B2E) }
    static var knobBodyDark: Color { Color(argb: 0xFF1B1511) }
    static var knobKnurl: Color { Color(argb: 0xFF0E0B08) }
    static var knobCapLight: Color { Color(argb: 0xFF5C4A3A) }
    static var knobCapDark: Color { Color(argb: 0xFF2A211A) }
    /// Piano keys (RollDialog.kt:484-494): up / down gradients, front edge, border, lamp.
    static var keyUpTop: Color { Color(argb: 0xFFF4EBD3) }
    static var keyUpBottom: Color { Color(argb: 0xFFD6C8A6) }
    static var keyDownTop: Color { Color(argb: 0xFFB9AC8E) }
    static var keyDownBottom: Color { Color(argb: 0xFFA89A7B) }
    static var keyFront: Color { Color(argb: 0xFF8A7B5E) }
    static var keyBorder: Color { Color(argb: 0xFF6E604A) }
    static var keyLamp: Color { Color(argb: 0xFFB8402F) }
    /// Time-lapse small keys up / down (Timelapse.kt:163).
    static var smallKeyUp: Color { Color(argb: 0xFFEDE3C8) }
    static var smallKeyDown: Color { Color(argb: 0xFFB9AC8E) }
}

// MARK: - Shapes and surfaces

/// Compose RoundedCornerShape(r.dp): circular corners (SwiftUI's default is .continuous, which
/// looks softer). `cineRect(s(24))` in Android dp, scaled by the caller.
func cineRect(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .circular) }

private struct PlateSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.cineScale) private var s
    let shape: S
    let fill: Color
    let border: Color?
    let borderWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .overlay {
                if let border { shape.strokeBorder(border, lineWidth: s(borderWidth)) }
            }
            .clipShape(shape)
            .contentShape(shape)
    }
}

extension View {
    /// Compose `.clip(shape).background(fill).border(width.dp, border, shape)`: the floating plate
    /// look. Border width in Android dp (drawn inside the edge, as Compose).
    func plate<S: InsettableShape>(_ shape: S, fill: Color = Color.plate, border: Color? = nil, borderWidth: CGFloat = 1) -> some View {
        modifier(PlateSurface(shape: shape, fill: fill, border: border, borderWidth: borderWidth))
    }
    /// Plate capsule (Android RoundedCornerShape(50)).
    func plateCapsule(fill: Color = Color.plate, border: Color? = nil, borderWidth: CGFloat = 1) -> some View {
        plate(Capsule(), fill: fill, border: border, borderWidth: borderWidth)
    }
    /// Plate circle (round keys). Default border: 1dp Edge.
    func plateCircle(fill: Color = Color.plate, border: Color? = Color.edge, borderWidth: CGFloat = 1) -> some View {
        plate(Circle(), fill: fill, border: border, borderWidth: borderWidth)
    }

    /// THE selection language (CameraScreen.kt:1780-1784): a 1.5dp Brass underline whose centre is
    /// 2dp below the view's bottom edge. Apply after the option's own padding, as on Android.
    func brassMark(_ on: Bool, color: Color = Color.brass) -> some View {
        modifier(BrassMark(on: on, color: color))
    }
}

private struct BrassMark: ViewModifier {
    @Environment(\.cineScale) private var s
    let on: Bool
    let color: Color
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if on {
                // Line centre at bottom + 2dp, 1.5dp thick: from bottom + 1.25dp to bottom + 2.75dp.
                Rectangle().fill(color).frame(height: s(1.5)).offset(y: s(2.75))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A plain press look for every Cine key: no system highlight, buzz on press (Android: default
/// indication, Haptics.kt). Dims a little while held.
struct CinePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onChange(of: configuration.isPressed) { _, down in if down { Haptics.tap() } }
    }
}

// MARK: - Keys and pills

/// Android `Pill` (CameraScreen.kt:1768-1778): Plate capsule, 1dp border Brass when selected else
/// none, padding 13x7dp, 0.4 alpha when disabled. Text inside defaults to Jost 15sp Ivory.
/// Used for WB / AF / zoom keys, Close, every text button in settings.
///
///     CinePill(action: close) { Text("Close") }
///     CinePill("Sync now", selected: on) { ... }
struct CinePill<Content: View>: View {
    @Environment(\.cineScale) private var s
    var selected = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.selected = selected
        self.enabled = enabled
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content() }
                .font(s.font(15))
                .foregroundStyle(Color.ivory)
                .padding(.horizontal, s(13))
                .padding(.vertical, s(7))
                .plateCapsule(border: selected ? Color.brass : nil)
                .opacity(enabled ? 1 : Theme.disabledAlpha)
        }
        .buttonStyle(CinePressStyle())
        .disabled(!enabled)
    }
}

extension CinePill where Content == Text {
    init(_ title: String, selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.init(selected: selected, enabled: enabled, action: action) { Text(title) }
    }
}

/// The round key (settings gear CameraScreen.kt:1740-1749, play :1380-1408, trash :1412-1420):
/// a `size`dp circle, Plate, 1dp Edge border. Player uses 56, library bar 52, the X in dialogs 72,
/// focus lock 40, ring toggle 30. `border: nil` for the borderless Help close.
///
///     CineRoundKey(action: openSettings) { CineIcon(.gear) }
struct CineRoundKey<Content: View>: View {
    @Environment(\.cineScale) private var s
    var size: CGFloat = 52
    var fill: Color = Color.plate
    var border: Color? = Color.edge
    var borderWidth: CGFloat = 1
    var enabled = true
    /// Android's disabled look for this key (library bar: 0.35, else 0.4 via Faint icon colour).
    var disabledAlpha: Double = 1
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(size: CGFloat = 52, fill: Color = Color.plate, border: Color? = Color.edge, borderWidth: CGFloat = 1, enabled: Bool = true,
         disabledAlpha: Double = 1, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.size = size
        self.fill = fill
        self.border = border
        self.borderWidth = borderWidth
        self.enabled = enabled
        self.disabledAlpha = disabledAlpha
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            ZStack { content() }
                .frame(width: s(size), height: s(size))
                .plateCircle(fill: fill, border: border, borderWidth: borderWidth)
                .opacity(enabled ? 1 : disabledAlpha)
        }
        .buttonStyle(CinePressStyle())
        .disabled(!enabled)
    }
}

/// A capsule key with a border that turns Brass when on: Track (CameraScreen.kt:698-712, 52dp tall,
/// padding 22), Auto under the drums (:1114-1124, 38dp tall, full width), level pill frame.
struct CineCapsuleKey<Content: View>: View {
    @Environment(\.cineScale) private var s
    var height: CGFloat = 52
    var horizontalPadding: CGFloat = 22
    var on = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(height: CGFloat = 52, horizontalPadding: CGFloat = 22, on: Bool = false, enabled: Bool = true,
         action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.on = on
        self.enabled = enabled
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content() }
                .font(s.font(15))
                .foregroundStyle(Color.ivory)
                .padding(.horizontal, s(horizontalPadding))
                .frame(height: s(height))
                .plateCapsule(border: on ? Color.brass : Color.edge)
                .opacity(enabled ? 1 : Theme.disabledAlpha)
        }
        .buttonStyle(CinePressStyle())
        .disabled(!enabled)
    }
}

// MARK: - Text-only options (settings Opt, AF / MF, Photo / Video, zoom keys)

/// One engraved option (CameraScreen.kt:2196-2208): selected = Ivory w500 + brass mark, others
/// Faint w400 (zoom keys use Dim: pass `offColor: .dim`). 2dp vertical padding inside the mark.
struct CineOption: View {
    @Environment(\.cineScale) private var s
    let title: String
    var selected: Bool
    var enabled = true
    var sp: CGFloat = 15
    var offColor: Color = Color.faint
    let action: () -> Void

    init(_ title: String, selected: Bool, enabled: Bool = true, sp: CGFloat = 15, offColor: Color = Color.faint, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.enabled = enabled
        self.sp = sp
        self.offColor = offColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(s.font(sp, selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.ivory : offColor)
                .lineLimit(1)
                .padding(.vertical, s(2))
                .brassMark(selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(CinePressStyle())
        .disabled(!enabled)
    }
}

/// Settings `Opt` row: label left (Ivory 15sp), the options right in a flowing row spaced 14dp
/// (7dp for 0..10 scales), 6dp between lines, 5dp row padding; the label goes above when it doesn't
/// fit beside them (LabelRow, :2165-2189). Whole row 0.4 alpha when disabled.
struct CineOptionRow<T: Hashable>: View {
    @Environment(\.cineScale) private var s
    let label: String
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T
    var enabled = true
    var spacing: CGFloat = 14

    init(_ label: String, options: [T], selection: Binding<T>, enabled: Bool = true, spacing: CGFloat = 14,
         title: @escaping (T) -> String) {
        self.label = label
        self.options = options
        self._selection = selection
        self.enabled = enabled
        self.spacing = spacing
        self.title = title
    }

    var body: some View {
        CineLabelRow {
            Text(label).font(s.font(15)).foregroundStyle(Color.ivory)
        } controls: {
            FlowRow(spacing: s(spacing), lineSpacing: s(6)) {
                ForEach(options, id: \.self) { o in
                    CineOption(title(o), selected: o == selection, enabled: enabled) { selection = o }
                }
            }
        }
        .padding(.vertical, s(5))
        .opacity(enabled ? 1 : Theme.disabledAlpha)
    }
}

extension CineOptionRow where T == String {
    init(_ label: String, options: [String], selection: Binding<String>, enabled: Bool = true, spacing: CGFloat = 14) {
        self.init(label, options: options, selection: selection, enabled: enabled, spacing: spacing) { $0 }
    }
}

/// Android `LabelRow`: the label left and the controls right when the label fits beside them in up to
/// two lines, else the label above (4dp) and the controls under it. Gap 12dp.
struct CineLabelRow<Label: View, Controls: View>: View {
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
        LabelRowLayout(gap: s(12), top: s(4), twoLines: twoLines) {
            label()
            controls()
        }
    }
}

private struct LabelRowLayout: Layout {
    let gap: CGFloat
    let top: CGFloat
    let twoLines: Bool

    private func plan(_ proposal: ProposedViewSize, _ v: Subviews) -> (side: Bool, width: CGFloat, label: CGSize, ctrl: CGSize) {
        let width = proposal.width ?? .infinity
        let ctrl = v[1].sizeThatFits(.unspecified)
        let one = v[0].sizeThatFits(.unspecified)
        let room = width - ctrl.width - gap
        if room > 0 {
            if one.width <= room { return (true, width, one, ctrl) }
            if twoLines {
                let wrapped = v[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
                if wrapped.width <= room + 0.5, wrapped.height <= one.height * 2 + 1 { return (true, width, wrapped, ctrl) }
            }
        }
        let lab = v[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return (false, width, lab, ctrl)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let p = plan(proposal, subviews)
        let w = p.width.isFinite ? p.width : (p.side ? p.label.width + gap + p.ctrl.width : max(p.label.width, p.ctrl.width))
        let h = p.side ? max(p.label.height, p.ctrl.height) : p.label.height + top + p.ctrl.height
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let p = plan(ProposedViewSize(width: bounds.width, height: nil), subviews)
        if p.side {
            let h = bounds.height
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (h - p.label.height) / 2),
                              proposal: ProposedViewSize(p.label))
            subviews[1].place(at: CGPoint(x: bounds.maxX - p.ctrl.width, y: bounds.minY + (h - p.ctrl.height) / 2),
                              proposal: ProposedViewSize(p.ctrl))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(p.label))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + p.label.height + top),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// Compose FlowRow: children left to right, wrapping to a new line; `spacing` between items,
/// `lineSpacing` between lines (points, already scaled).
struct FlowRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ maxWidth: CGFloat, _ v: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, sv) in v.enumerated() {
            let sz = sv.sizeThatFits(.unspecified)
            // 0.5 pt slack: the width it is placed in can round a hair under the width it measured.
            if !rows[rows.count - 1].isEmpty, x + spacing + sz.width > maxWidth + 0.5 {
                rows.append([])
                x = 0
            }
            x += (rows[rows.count - 1].isEmpty ? 0 : spacing) + sz.width
            rows[rows.count - 1].append((i, sz))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rs = rows(proposal.width ?? .infinity, subviews)
        var w: CGFloat = 0
        var h: CGFloat = 0
        for (n, r) in rs.enumerated() {
            let rw = r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(r.count - 1, 0))
            w = max(w, rw)
            h += (r.map { $0.1.height }.max() ?? 0) + (n > 0 ? lineSpacing : 0)
        }
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(bounds.width, subviews) {
            let rh = r.map { $0.1.height }.max() ?? 0
            var x = bounds.minX
            for (i, sz) in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (rh - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += rh + lineSpacing
        }
    }
}

/// Settings `Note` (:2191-2194): Dim 13sp, 4dp top padding.
struct CineNote: View {
    @Environment(\.cineScale) private var s
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(s.font(13)).foregroundStyle(Color.dim).padding(.top, s(4))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dialogs

/// Full-screen scrim that swallows taps, content centred (ConfirmDialog :1689, VoiceNote :1519).
/// `.scrim` (#99000000) for confirm / voice note, `.scrimDark` (#AA000000) for moves / time-lapse / sort.
struct CineScrim<Content: View>: View {
    var color: Color = Color.scrim
    var onTapOutside: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    init(color: Color = Color.scrim, onTapOutside: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.color = color
        self.onTapOutside = onTapOutside
        self.content = content
    }

    var body: some View {
        ZStack {
            color.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onTapOutside?() }
            content()
        }
    }
}

/// The dialog panel: RoundedCornerShape(24dp), Sheet fill, 1dp Edge border, padding 40x28dp
/// (ConfirmDialog, VoiceNote; the marked dialog uses padding 28x22: pass it).
struct CineSheetPanel<Content: View>: View {
    @Environment(\.cineScale) private var s
    var radius: CGFloat = 24
    var paddingH: CGFloat = 40
    var paddingV: CGFloat = 28
    @ViewBuilder let content: () -> Content

    init(radius: CGFloat = 24, paddingH: CGFloat = 40, paddingV: CGFloat = 28, @ViewBuilder content: @escaping () -> Content) {
        self.radius = radius
        self.paddingH = paddingH
        self.paddingV = paddingV
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) { content() }
            .font(s.font(15))
            .foregroundStyle(Color.ivory)
            .padding(.horizontal, s(paddingH))
            .padding(.vertical, s(paddingV))
            .plate(cineRect(s(radius)), fill: Color.sheet, border: Color.edge)
    }
}

/// The red "Yes" capsule: 150x72dp, Red, "Yes" white 26sp w600 (:1700-1703). Voice note's Record is
/// the same at 170x72 with its own label: use `width: 170` and the content init.
struct CineYesButton<Content: View>: View {
    @Environment(\.cineScale) private var s
    var width: CGFloat = 150
    var height: CGFloat = 72
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(width: CGFloat = 150, height: CGFloat = 72, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.width = width
        self.height = height
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content() }
                .font(s.font(26, .semibold))
                .foregroundStyle(Color.white)
                .frame(width: s(width), height: s(height))
                .background(Capsule().fill(Color.rec))
                .contentShape(Capsule())
        }
        .buttonStyle(CinePressStyle())
    }
}

extension CineYesButton where Content == Text {
    init(_ title: String = "Yes", width: CGFloat = 150, height: CGFloat = 72, action: @escaping () -> Void) {
        self.init(width: width, height: height, action: action) { Text(title) }
    }
}

/// The round X: a `size`dp Plate circle, 1dp Edge, CrossIcon `cross`dp Ivory. Dialog No = 72 / 26;
/// focus ring close 34 / 13; Help close 52 / 20 without border; player close 56 / 20.
struct CineCloseKey: View {
    var size: CGFloat = 72
    var cross: CGFloat = 26
    var border: Color? = Color.edge
    let action: () -> Void

    init(size: CGFloat = 72, cross: CGFloat = 26, border: Color? = Color.edge, action: @escaping () -> Void) {
        self.size = size
        self.cross = cross
        self.border = border
        self.action = action
    }

    var body: some View {
        CineRoundKey(size: size, border: border, action: action) { CineIcon(.cross, size: cross) }
    }
}

/// Android `ConfirmDialog` (:1689-1713): scrim, panel, title 24sp w500, body Dim 14sp, then Yes and X
/// 28dp apart. Only Yes goes ahead. Put it over the screen (ZStack / overlay), not in a sheet.
struct CineConfirmDialog: View {
    @Environment(\.cineScale) private var s
    let title: String
    let text: String
    let onYes: () -> Void
    let onNo: () -> Void

    init(_ title: String, _ text: String, onYes: @escaping () -> Void, onNo: @escaping () -> Void) {
        self.title = title
        self.text = text
        self.onYes = onYes
        self.onNo = onNo
    }

    var body: some View {
        CineScrim {
            CineSheetPanel {
                Text(title).font(s.font(24, .medium))
                Spacer().frame(height: s(6))
                Text(text).font(s.font(14)).foregroundStyle(Color.dim).multilineTextAlignment(.center)
                Spacer().frame(height: s(24))
                HStack(spacing: s(28)) {
                    CineYesButton(action: onYes)
                    CineCloseKey(action: onNo)
                }
            }
        }
    }
}

// MARK: - Font check (screenshot run `-shot fonttest`)

/// Jost at 300 / 400 / 500 / 600 / 700, the palette, every icon and the shared keys: to check on
/// the simulator that the font loads, the weights differ, and the pieces look like Android.
struct ThemeSpecimen: View {
    @Environment(\.cineScale) private var s
    private let swatches: [(String, Color)] = [
        ("Ivory", .ivory), ("Dim", .dim), ("Faint", .faint), ("Brass", .brass), ("Red", .rec), ("Edge", .edge),
        ("Drum", .drum), ("Sheet", .sheet), ("Live", .live), ("Blue", .moveBlue), ("Amber", .starAmber), ("Green", .okGreen),
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Jost.isLoaded ? "Jost loaded (\(Jost.postScriptName))" : "JOST NOT LOADED: system font")
                        .font(.jost(13, .medium)).foregroundStyle(Jost.isLoaded ? Color.okGreen : Color.rec)
                    ForEach([300, 400, 500, 600, 700], id: \.self) { w in
                        Text("\(w)  720p30 HLG 10-bit  Yes  Settings").font(.jost(20, wght: CGFloat(w)))
                    }
                    Text("Camera 15sp = \(String(format: "%.1f", Theme.cam(15))) pt").font(.cam(15))
                    Text("Settings 15sp = \(String(format: "%.1f", Theme.settings(15))) pt").font(.settings(15))
                    HStack(spacing: 4) {
                        ForEach(swatches.indices, id: \.self) { i in
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 3).fill(swatches[i].1).frame(width: 26, height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.2)))
                                Text(swatches[i].0).font(.jost(8))
                            }
                        }
                    }
                    HStack(spacing: s(5)) {
                        CinePill("WB 5500 K") {}
                        CinePill(action: {}) {
                            CineOption("AF", selected: true) {}
                            Spacer().frame(width: s(10))
                            CineOption("MF", selected: false) {}
                        }
                        CinePill("Close", selected: true) {}
                        CineCapsuleKey(on: true, action: {}) { Text("Track").font(s.font(18)) }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FlowRow(spacing: 8, lineSpacing: 8) {
                        ForEach(CineIconKind.specimen, id: \.self) { k in
                            CineRoundKey(action: {}) { CineIcon(k) }
                        }
                        CineRoundKey(action: {}) { CineGimbalBadge(connected: false) }
                        CineRoundKey(action: {}) { CineGimbalBadge(connected: true) }
                    }
                    .frame(width: 330)
                    HStack(spacing: s(28)) {
                        CineYesButton {}
                        CineCloseKey {}
                    }
                }
            }
            .foregroundStyle(Color.ivory)
            .padding(16)
        }
    }
}

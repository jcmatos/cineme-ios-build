# Theme API (iPhone restyle to match Android)

Files: `Theme.swift` (scale, font, colours, shared keys, dialogs), `Icons.swift` (all Android Canvas
icons), `Fonts/Jost.ttf`. Android reference: `DEVELOPMENT_FILES/android-ref/DESIGN.md` + screenshots.

Rule: write every size with the **Android number** (dp / sp from the Kotlin) and let the scale convert it.

## Scale

| Area | Android density | iOS pt per dp | How |
|---|---|---|---|
| Camera screen, its dialogs (confirm, voice note, help, moves, time-lapse, focus ring, level) | 0.8 | 0.782 | default; `Theme.cam(x)`, `.font(.cam(15))` |
| Settings sheet (+ Remote) | 1.04 | 1.017 | `.cineScale(.settings)` on the sheet; `Theme.settings(x)`, `.font(.settings(15))` |
| Player + library | 0.8 | 0.782 | `.cineScale(.player)`; `Theme.player(x)`, `.font(.player(15))` |

Why: dp and pt are both 1/160 inch. The screenshots are a Pixel 6 (411 dp short side), the target is an
iPhone 18 Pro (402 pt short side), so `Theme.device = 402/411 = 0.978` keeps every element the same share
of the screen height (Android lays out against the landscape height). Times Android's own 0.8 / 1.04.

In a view: `@Environment(\.cineScale) private var s` then `s(52)` (dp -> pt), `s.font(15, .medium)`,
`s.tracking(0.08, sp: 12)` (Compose letterSpacing em -> `.tracking`). All shared views below read `s`.
`Theme.tracking(em, sp:, scale:)` does the same without the environment.

## Font

- `Font.jost(_ size: CGFloat, _ weight: Font.Weight = .regular)`: size in **points**. `.light` 300,
  `.regular` 400, `.medium` 500, `.semibold` 600, `.bold` 700 (Compose `FontWeight(n)`).
- `Font.jost(_ size: CGFloat, wght: CGFloat)`: any axis value 100...900.
- `Font.cam(sp, weight)`, `Font.settings(sp, weight)`, `Font.player(sp, weight)`: size in Android sp.
- `Jost.uiFont(size, wght:)` for UIKit; `Jost.isLoaded`; PostScript name `Jost-Regular`.
- `View.cineDefaultText(.cam)`: Android's default text, Jost 15sp Ivory.
- The weight is set on the variable font's `wght` axis (kCTFontVariationAttribute), so weights are real.

## Colours (`Color.x` and `.foregroundStyle(.x)`, `.fill(.x)`)

Palette: `ivory` #EDE6D6, `dim` #8D877A, `faint` #6D685D, `brass` #B8955A, `rec` #D7261E (Android Red),
`plate` #A8000000, `drum` #151413, `edge` #3A3833, `sheet` #0D0C0B, `live` #7FA06A, `moveBlue` #3D7FE0
(Android Blue).
Camera extras: `drumNear`, `recWell`, `recWellBlue`, `shutterBody`, `scrim` #99000000, `scrimDark`
#AA000000, `navColumn` #141210, `navSelectedText`, `scrollBar`, `focusWide`, `armsYellow`, `toastSaved`,
`toastNoSound`, `paradeR/G/B`, `histogramFrame`, `logText`.
Secondary: `starAmber`, `okGreen` #3FBF5F, `levelYellow`, `ringRidge`, `ringMarker`, `guideLine`,
`libraryBar`, `toastBack`, `sortCard`, `tile`, `remoteStand/Face/Button`.
Radio dialogs: `walnut`, `walnutDark`, `dialGlass`, `dialInk`, `amber`, `walnutHint`, `dialSky`,
`liveMove`, `knobTick`, `knobShadow`, `knobBodyLight/Dark`, `knobKnurl`, `knobCapLight/Dark`,
`keyUpTop/Bottom`, `keyDownTop/Bottom`, `keyFront`, `keyBorder`, `keyLamp`, `smallKeyUp/Down`.
`Color(argb: 0xAARRGGBB)` for anything else. (No `red`/`blue`/`green`: SwiftUI has those.)

## Surfaces and modifiers

| Swift | Android |
|---|---|
| `.plate(shape, fill: .plate, border: nil, borderWidth: 1)` | `.clip(shape).background(Plate).border(1.dp, c, shape)`; border dp, inside the edge |
| `.plateCapsule(border:)` / `.plateCircle(border: .edge)` | RoundedCornerShape(50) / CircleShape |
| `cineRect(s(24))` | RoundedCornerShape(24.dp) (circular corners, not SwiftUI's continuous) |
| `.brassMark(on)` | `brassMark`: 1.5dp Brass line 2dp under the view (apply after the option's padding) |
| `CinePressStyle()` | press look + 12ms buzz on press start. **Cine keys already buzz: don't call `Haptics.tap()` in their actions.** |

## Keys

| Swift | Android |
|---|---|
| `CinePill(selected:enabled:action:) { ... }`, `CinePill("Close") { }` | `Pill` :1768: Plate capsule, Brass 1dp border when selected, 13x7 padding, alpha 0.4 disabled, Jost 15 Ivory |
| `CineRoundKey(size: 52, fill:, border: .edge, enabled:, disabledAlpha:, action:) { CineIcon(.gear) }` | gear / play / trash 52, player 56, mark keys 72, focus lock 40, ring toggle 30, library bar 52 (on = `fill: .starAmber`, `disabledAlpha: 0.35`) |
| `CineCapsuleKey(height: 52, horizontalPadding: 22, on:, action:) { Text("Track") }` | Track :698 (Edge border, Brass when on), Auto :1114 (height 38) |
| `CineOption("AF", selected:, enabled:, sp: 15, offColor: .faint) { }` | engraved option: Ivory w500 + brass mark / Faint w400; zoom keys `offColor: .dim` |
| `CineOptionRow("Resolution", options:, selection: $x, spacing: 14) { title }` | settings `Opt` :2196 (label left, flowing options right, label above when tight) |
| `CineLabelRow { label } controls: { ... }` | `LabelRow` :2170 |
| `FlowRow(spacing:, lineSpacing:)` | Compose FlowRow (points, already scaled) |
| `CineNote("...")` | `Note`: Dim 13sp, 4dp top |

## Dialogs

| Swift | Android |
|---|---|
| `CineScrim(color: .scrim, onTapOutside:) { ... }` | full-screen #99000000 (or `.scrimDark`), swallows taps |
| `CineSheetPanel(radius: 24, paddingH: 40, paddingV: 28) { ... }` | panel: 24dp, Sheet, 1dp Edge |
| `CineYesButton("Yes") { }` / `CineYesButton(width: 170) { HStack { ... } }` | 150x72 Red capsule, white 26sp w600 (voice note Record 170x72) |
| `CineCloseKey(size: 72, cross: 26, border: .edge) { }` | round X (dialog No 72/26, focus ring 34/13, Help 52/20 `border: nil`, player 56/20) |
| `CineConfirmDialog(title, text, onYes:, onNo:)` | `ConfirmDialog` :1689, whole thing. Overlay it on the screen. |

## Icons (`Icons.swift`)

`CineIcon(_ kind, size: dpWidth? = nil, color: Color? = nil)`. Default size = Android box, default colour
Ivory (drumIndex Red, bin walnutHint, dialPlay/dialStop DialInk 80%). Kinds: `.gear .lock(closed:)
.storage .battery(level:) .refresh .moves .vibrate .trash .mic .uploading (animated) .center .cross
.play .drumIndex .focusPoint .focusBrackets .ringToggle .sort .undo .compare .single .expand
.star(filled:) .pin .grid .bracket(isIn:) .speaker(muted:) .chevron(left:) .stopwatch .bin .dialPlay
.dialStop`. Kotlin line for each: comment at the top of Icons.swift.
`CineGimbalBadge(connected:)`: the 22dp "G" (Live / Red).

## Check

`-shot fonttest` (CameraScreen's Shot switch) shows `ThemeSpecimen`: Jost 300-700, palette, every icon in
a round key, pills, Yes / X. Add `fonttest:landscape` to the list in `.github/workflows/ios-shots.yml` to
get it as a screenshot.

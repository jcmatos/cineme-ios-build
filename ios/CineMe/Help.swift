import SwiftUI

// Help page: how to use CineMe on the iPhone, one section per part of the screen. Port of the
// Android Help.kt (HelpSheet), with only what the iPhone app has (no filters, stand-by or SD card here).
// Opened from Settings > Help (full screen over the settings); -shot help opens it by itself.

/// Android HelpSheet (Help.kt:31): full-screen Sheet, padding 36x18, "Help" 26sp w500 and a 52dp
/// Plate close (no border); the text up to 760dp wide: section titles Brass 14sp 0.1em w500,
/// lines "•" Dim + 15sp. Camera scale (x0.8).
struct HelpPanel: View {
    var sections: [(String, [String])] = helpSections
    let onClose: () -> Void
    private let s = CineScale.cam

    init(sections: [(String, [String])] = helpSections, onClose: @escaping () -> Void) {
        self.sections = sections
        self.onClose = onClose
    }

    var body: some View {
        // Full screen like Android (36dp margins from the screen edge): the reader takes the whole
        // screen and keeps clear of the Dynamic Island / home bar only by PaneSafeArea's share.
        GeometryReader { g in
            content.padding(PaneSafeArea.overlap(g.frame(in: .global)))
        }
        .ignoresSafeArea()
        .background(Color.sheet.ignoresSafeArea().onTapGesture {})
        .cineScale(.cam)
        .cineDefaultText(.cam)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Help").font(s.font(26, .medium)).foregroundStyle(Color.ivory)
                Spacer(minLength: s(8))
                CineCloseKey(size: 52, cross: 20, border: nil, action: onClose)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, sec in
                        Spacer().frame(height: s(18))
                        Text(sec.0)
                            .font(s.font(14, .medium))
                            .tracking(s.tracking(0.1, sp: 14))
                            .foregroundStyle(Color.brass)
                        ForEach(Array(sec.1.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text("•").font(s.font(15)).foregroundStyle(Color.dim)
                                    .padding(.trailing, s(10))
                                Text(line).font(s.font(15)).foregroundStyle(Color.ivory)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, s(6))
                        }
                    }
                    Spacer().frame(height: s(40))
                }
                .frame(maxWidth: s(760), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, s(36))
        .padding(.vertical, s(18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Help on its own (old `.sheet { HelpSheet() }` callers).
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HelpPanel { dismiss() }
    }
}

let helpSections: [(String, [String])] = [
    ("RECORDING", [
        "Red button: start / stop a video. Photo / Video above it switches mode (not while recording); in photo mode the button is white and takes a photo.",
        "One beep when recording starts, two when it stops. Settings > Video > Record signal: beeps, vibrate or silent.",
        "The gimbal's record button, a remote, the volume keys, the Camera Control and the Action button do the same as the red button (Settings > Remote).",
        "A take that wasn't recorded: a big red VIDEO NOT RECORDED and an alarm. Tap it to stop the alarm. Why it failed is in the take log (TAKE LOG below).",
    ]),
    ("PHOTOS", [
        "Each photo is an Apple ProRAW file (.dng) and a HEIC (or JPEG) with the same name, like RAW + JPEG on Android.",
        "They stay in Files > On My iPhone > CineMe > CineMe Photos. A copy goes to Photos as one picture (RAW + HEIC) unless Copy to Photos is off.",
        "Settings > Photo: RAW on or off, HEIC or JPEG, slowest shutter for Auto. ProRAW is big: about 75 MB a photo at 48 MP.",
    ]),
    ("TOP BAR", [
        "Red dot and timer while recording, the format (in photo mode: ProRAW + HEIC and the size), free space and battery. A drive icon when recording to a USB-C drive.",
        "G: green = gimbal connected, red = not. Tap it for the gimbal settings and its log; hold it to look for the gimbal again.",
        "The level pill next to it: see LEVEL AND GIMBAL MOVES.",
        "A small moving arrow left of the level = uploading (see BACKUP).",
    ]),
    ("EXPOSURE", [
        "ISO and Shutter on the left: tap one for its slider. Moving a slider turns Auto off.",
        "Auto under them: the camera sets the light by itself (brass = on). The gimbal (T held) and the remote's Auto light measure once and keep it.",
        "The shutter can't be slower than the frame rate (1/30 at 30 fps).",
        "WB at the bottom: tap for the Kelvin slider (2000 to 10000 K) and Auto.",
    ]),
    ("FOCUS", [
        "Tap the image to focus there (and to measure the light there, with Auto on).",
        "AF / MF at the bottom: tap for the focus slider, Near to Far, and Auto.",
        "A remote can pull focus: Focus closer / Focus farther in Settings > Remote.",
    ]),
    ("FOCUS RING", [
        "In MF, the round arrow next to the focus slider: a focus ring takes the place of ISO and Shutter.",
        "Turn it round and round like a lens ring: clockwise = farther, anticlockwise = closer. About 4 turns from closest to farthest.",
        "The bar in the middle shows where the lens is, near to far. X goes back to ISO and Shutter.",
    ]),
    ("PICTURE AIDS", [
        "Histogram (Settings > Screen): top left. Tap it for the RGB parade, then the waveform. A red line on the right = blown highlights, brass on the left = crushed blacks.",
        "Focus peaking (Settings > Focus): red marks on the edges in focus. Sensitivity = how many edges, colour = how strong the red.",
        "Show sharp areas (Settings > Focus): in AF, small green brackets where the picture is sharp.",
        "Grid (thirds) and golden spiral (Settings > Screen): drawn over the picture only, never recorded. The spiral's arrow is the corner its wide curve starts from.",
        "Histogram, peaking and sharp areas are off with ProRes (the camera can't send the frames then).",
    ]),
    ("APERTURE AND LENSES", [
        "f/A: the camera picks the aperture. Tap it for the stops the lens has (iPhone 18 Pro main camera); Auto gives it back to the camera.",
        "0.5x, 1x, 2x, 4x, 8x in the bottom bar. 2x and 8x are crops of the 48 MP cameras. Not while recording.",
        "100 and 120 fps: the 1x camera only.",
    ]),
    ("GIMBAL (ZHIYUN SMOOTH-Q)", [
        "The app connects by itself, also if the gimbal is turned on later.",
        "Record button: start / stop (also stops a time-lapse). A long press turns the gimbal off.",
        "W/T slider: a short push = one third of a stop brighter (W) or darker (T). Held: W = next lens, T = Auto light.",
        "MODE stops tracking.",
        "Tap the G: follow speed (1 smooth to 5 fast), joystick speed, a key test and the Bluetooth log. The same speeds are in Settings > Gimbal.",
    ]),
    ("BLUETOOTH REMOTE", [
        "A ring remote (like the JX-05) works next to the gimbal. Pair it once in the iPhone's Bluetooth settings.",
        "Settings > Remote: Calibrate, then press each button when asked. Tap a button to pick what it does (record, lens, focus, light, Maps, gimbal moves, level).",
        "Defaults: middle = record, up / down = brighter / darker, left = Auto, right = next lens.",
        "Volume up and down (also the Camera Control, the Action button and AirPods): record, unless set otherwise. Only while the camera runs.",
        "Maps opens Google Maps (or Apple Maps). Come back with ‹ CineMe at the top left.",
    ]),
    ("TRACKING", [
        "Track (bottom bar), then drag a box round the subject (or tap it). The gimbal keeps the subject where you picked it, not in the centre.",
        "Track again, or MODE on the gimbal, stops it.",
        "Settings > Tracking: smoothness, max speed, dead zone, pan only, directions.",
        "Arms trigger (Settings > Tracking): film yourself. Stand 3 to 10 m in front of the camera, raise both arms above your head and hold a second: the light flashes once, it records and tracks you. Arms up again: it stops and flashes twice.",
        "Not with ProRes (the camera can't send the frames then), not during a time-lapse.",
    ]),
    ("LEVEL AND GIMBAL MOVES", [
        "Level pill (top right): the water stays flat while the phone turns. Green = level, yellow = a little off, red = a lot.",
        "Tap the pill: the gimbal turns the horizon slowly until it is level (brass edge while it works). Tap again to stop.",
        "Hold the pill, or Move in the bottom bar: gimbal moves. ROLL turns the horizon, TILT points the camera up or down, PAN looks left / right.",
        "Angle: Go there turns to one angle. Move: start, end and time; Set makes record run it start to end and back, round again until you stop.",
        "Save keeps the move in a list. Use loads a saved one, Edit puts it on the controls.",
        "With a move set, record is blue. Remove the move: record keeps the gimbal still.",
        "Pan counts from where the camera looks when you press Set or Use.",
    ]),
    ("TIME-LAPSE", [
        "Time-lapse (bottom bar): a photo every few seconds for as long as you choose, played as a clip at 24, 25 or 30 fps. The panel shows the clip length, photos, how much faster and when it ends.",
        "A saved move can be spread over the whole shoot: its start at the first photo, its end at the last.",
        "Record, or Time-lapse again, stops it early; the clip is kept. No sound. Not with ProRes RAW. Keep the phone plugged in for long ones.",
    ]),
    ("VIDEO MANAGER", [
        "Play key (right): the clips on the iPhone as a grid. − / + or pinch: more or fewer across. Not while recording.",
        "Tap a clip: full screen. Tap = pause / play; drag left / right = scrub (one screen width = the whole clip).",
        "Star: keep it (it can't be deleted until the star is off). Bin: kept 30 days, with Undo (the curved arrow).",
        "Order: newest / oldest, biggest / smallest, longest / shortest, starred first, name.",
        "IN / OUT: the part to keep, green on the bar and on the tile.",
        "Sound is off until you turn it on.",
    ]),
    ("VIDEO MANAGER, FROM THE GIMBAL", [
        "W / T short push: 2 s forward / back.",
        "W / T held: fast forward / back. Let go to stop.",
        "Record: next clip. Two fast clicks: previous clip.",
        "Don't hold record alone: a long press turns the gimbal off.",
    ]),
    ("VOICE NOTES", [
        "Mic key (right, not while recording): record a note about a bug or an idea for the app.",
        "Stop saves the note and goes back to filming. X while recording asks to reject it (thrown away).",
        "The panel lists the notes on the phone; Send notes shares them. Also in Files > On My iPhone > CineMe > CineMe Notes.",
    ]),
    ("BACKUP", [
        "Small copies of clips (540p) and photos (1600 px) go to cineme.studiowebworks.com/videos. The originals stay on the iPhone.",
        "CineMe's own and (Phone camera too) the iPhone camera's, everything since Fri 9 Oct.",
        "On the site, pick a day: everything is Keep. Delete only marks it.",
        "On the next sync the iPhone lists the marked ones (frame and name). Delete all, then Yes, deletes them here too. For the ones in Photos, iOS asks once more.",
        "Nothing converts while recording; it goes on after. A sync starts 1 minute after you stop recording (another take starts the minute again), and every 15 minutes while CineMe is open.",
        "An upload already started finishes with CineMe in the background. Converting needs CineMe open; iOS may also run it later in the background (often while charging).",
        "Settings > Backup: auto upload, Phone camera too, Wi-Fi only or mobile data too, Sync now. The site shows each video's length and how much space it takes on the phone.",
    ]),
    ("PLACE (GPS)", [
        "Settings > Save to > Place: where you are goes into every clip and photo, to group footage by place when editing. Photos shows it on its map.",
        "The first time, iOS asks to allow the location while using CineMe.",
    ]),
    ("TAKE LOG", [
        "Every take (start, file, why it failed), every photo and the app's start are written to rec-log.txt in Files > On My iPhone > CineMe.",
        "Settings > Save to > Send the take log shares it.",
    ]),
    ("SETTINGS", [
        "The gear (bottom right): settings over the left of the picture (the bottom in portrait). A page per subject in the column on the left; tap the picture or Close to go back.",
        "Video: resolution, frame rate, codec (HEVC, H.264, ProRes, ProRes RAW), colour (SDR, HDR Dolby Vision, Apple Log 2, Apple Log), record signal. Image: stabilization.",
        "Auto: where Auto aims, in steps of 0.2 stop. Photo: RAW, HEIC or JPEG, slowest shutter for Auto.",
        "Save to: this iPhone or a folder on a USB-C drive (ProRes 4K 120 fps needs the drive), Copy to Photos, Place, the take log.",
        "Screen: Vibrate on taps (with its strength), histogram, grid, golden spiral. Exposure: zebras and false colour. Focus: peaking and sharp areas.",
        "Sound: mono, stereo or spatial, wind, the microphone, the sound meters. Timecode and Anamorphic: their own pages.",
        "Backup, Tracking, Gimbal and Remote: their own pages. Formats: what the lens really has.",
        "Clips stay in the app (video manager, Files > On My iPhone > CineMe). Photos doesn't take ProRes RAW.",
    ]),
]

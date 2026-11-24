import SwiftUI

/// Settings > Remote, like Android's RemoteSettings.kt: is a keyboard-type remote there, calibrate it
/// (press each button once, so the app knows what each one sends), and what each button does. A
/// press lights its row up. Also what the phone's own buttons do (volume, Camera Control).
/// The page's content: SettingsPanel shows it under its own title and scroll.
struct RemoteSettingsContent: View {
    @Environment(\.cineScale) private var s
    @ObservedObject private var remote = Remote.shared
    @State private var open: String?
    @State private var lit: RemoteButton?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneValueRow("Status", status, color: remote.keyboard != nil ? Color.okGreen : Color.dim)
            FlowRow(spacing: s(6), lineSpacing: s(6)) {
                CinePill(remote.learning == RemoteButton.presses ? "Stop calibrating" : "Calibrate",
                         selected: remote.learning == RemoteButton.presses) { toggle(RemoteButton.presses) }
                CinePill(remote.learning == RemoteButton.holds ? "Stop" : "Learn holds",
                         selected: remote.learning == RemoteButton.holds) { toggle(RemoteButton.holds) }
            }
            .padding(.top, s(6))
            if remote.learning != nil {
                RmCalibrate(remote: remote)
            } else {
                buttons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Catches the remote here too (volume keys and keys while this page is up).
        .background(RemoteCatcher())
        .onAppear { if Shot.screen == "remote" { remote.fakeForShots() } }
        .onDisappear { remote.stopLearning() }
        .onChange(of: remote.lastPress) { _, p in
            guard let p = p else { return }
            lit = p.button
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if lit == p.button { lit = nil }
            }
        }
    }

    private var status: String {
        if let k = remote.keyboard { return "\(k): connected" }
        return remote.learned.isEmpty ? "Not calibrated" : "Remote: off"
    }

    private func toggle(_ order: [RemoteButton]) {
        if remote.learning == order { remote.stopLearning() } else { remote.startLearning(order) }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 0) {
            CineNote("Tap a button to choose what it does. Press a button on the remote: its row lights up.")
            ForEach(RemoteButton.presses) { b in row(b) }
            Text("Held (about 1 s)").font(s.font(13)).foregroundStyle(Color.dim).padding(.top, s(12))
            ForEach(RemoteButton.holds) { b in row(b) }
            Text("Phone buttons").font(s.font(13)).foregroundStyle(Color.dim).padding(.top, s(12))
            actionRow(id: "volUp", name: "Volume up", value: remote.volumeUp) { remote.volumeUp = $0 }
            actionRow(id: "volDown", name: "Volume down, Camera Control", value: remote.volumeDown) { remote.volumeDown = $0 }
            CineNote("Pair the remote once in the iPhone's Settings > Bluetooth (turn it on first), then Calibrate. " +
                     "The gimbal and the remote work at the same time.")
            CineNote("Remotes that send keys (arrows, Enter) or volume keys work. Remotes that swipe or tap the screen " +
                     "can't be told from a finger on the iPhone, so those don't.")
            CineNote("Held: a button held about 1 s does its held action. If the remote sends something else when held, " +
                     "tap Learn holds and hold each button once.")
            CineNote("A remote that sends volume keys can't be told from the phone's own volume buttons. " +
                     "The phone buttons only work while the camera is on. Volume down also covers the Camera Control, " +
                     "the Action button and AirPods.")
            CineNote("Maps: opens Google Maps (or Apple Maps). iOS can't bring CineMe back by itself: " +
                     "tap ‹ CineMe at the top left of Maps.")
        }
    }

    private func row(_ b: RemoteButton) -> some View {
        let known = remote.learned.values.contains(b) || (b.isHold && remote.learned.values.contains(b.base))
        return actionRow(id: b.rawValue, name: b.label, arrow: b.arrow, value: remote.action(b),
                         lit: lit == b, faint: !known && !remote.learned.isEmpty) { remote.setAction(b, $0) }
    }

    /// Android :116: r10 Plate row, padding 12x9, name in 120dp (Faint if not learned), action Brass;
    /// Brass 35% for a moment when its button is pressed. Tap: the actions under it. The arrow
    /// ("▲  Up") at Android's size (PaneArrow), two spaces' gap.
    @ViewBuilder
    private func actionRow(id: String, name: String, arrow: String? = nil, value: RemoteAction, lit: Bool = false,
                           faint: Bool = false, set: @escaping (RemoteAction) -> Void) -> some View {
        Button {
            open = open == id ? nil : id
        } label: {
            HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .center, spacing: s(11)) {
                    if let a = arrow { PaneArrow(a) }
                    Text(name)
                }
                .foregroundStyle(faint ? Color.faint : Color.ivory)
                .frame(width: s(120), alignment: .leading)
                Text(value.label).foregroundStyle(Color.brass)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(s.font(15))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, s(12)).padding(.vertical, s(9))
            .background(lit ? Color.brass.opacity(0.35) : Color.plate, in: cineRect(s(10)))
            .contentShape(cineRect(s(10)))
        }
        .buttonStyle(CinePressStyle())
        .padding(.top, s(6))
        if open == id {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(remote.offered) { a in
                    Button {
                        set(a)
                        open = nil
                    } label: {
                        Text(a.label).font(s.font(15, a == value ? .medium : .regular))
                            .foregroundStyle(a == value ? Color.ivory : Color.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, s(10)).padding(.vertical, s(7))
                            .background(a == value ? Color.plate : Color.clear, in: cineRect(s(8)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CinePressStyle())
                }
            }
            .padding(.leading, s(16)).padding(.top, s(4))
        }
    }
}

/// The Remote page on its own (old `.sheet { NavigationStack { RemoteSettingsView() } }` callers).
struct RemoteSettingsView: View {
    var body: some View {
        SettingsPageSheet(title: "Remote") { RemoteSettingsContent() }
    }
}

/// Press (or hold) each button in turn; the drawing shows which. Saved at the end (Android Calibrate :190).
private struct RmCalibrate: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var remote: Remote

    var body: some View {
        VStack(spacing: 0) {
            if let t = remote.target, let order = remote.learning {
                Text(t.isHold ? "HOLD \(t.arrow) \(t.base.label.uppercased()) (1 s)" : "Press \(t.arrow) \(t.label.uppercased())")
                    .font(s.font(24, .semibold)).foregroundStyle(Color.brass)
                Text("Button \(remote.step + 1) of \(order.count), the one blinking.")
                    .font(s.font(13)).foregroundStyle(Color.dim)
            }
            RmDrawing(target: remote.target?.base, done: Set(remote.got.keys.map { $0.base }))
                .frame(width: s(130), height: s(162)).padding(.vertical, s(10))
            if let m = remote.learnMessage {
                Text(m).font(s.font(14)).foregroundStyle(Color.ivory).multilineTextAlignment(.center)
            }
            HStack(spacing: s(6)) {
                if remote.target != nil { CinePill("Skip") { remote.skip() } }
                CinePill("Back", enabled: remote.step > 0) { remote.back() }
                CinePill("Cancel") { remote.stopLearning() }
            }
            .padding(.top, s(8))
            CineNote("Turn the remote on and make sure it's connected (Status). Each press is caught here, so it does nothing else.")
            if remote.learning?.first?.isHold == true {
                CineNote("Hold each button about 1 s. If one turns the screen off or leaves the app, Skip it.")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, s(10))
    }
}

/// The ring remote from above (RemoteSettings.kt:211): [target] pulses Brass, [done] get a green dot.
private struct RmDrawing: View {
    let target: RemoteButton?
    let done: Set<RemoteButton>

    private static let layout: [(RemoteButton, CGPoint)] = [
        (.up, CGPoint(x: 0.5, y: 0.22)), (.left, CGPoint(x: 0.22, y: 0.5)), (.center, CGPoint(x: 0.5, y: 0.5)),
        (.right, CGPoint(x: 0.78, y: 0.5)), (.down, CGPoint(x: 0.5, y: 0.78)),
    ]

    var body: some View {
        TimelineView(.animation) { tl in
            let pulse = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1)
            Canvas { ctx, size in
                let w = size.width, h = size.height
                ctx.fill(Path(roundedRect: CGRect(x: w * 0.3, y: h * 0.78, width: w * 0.4, height: h * 0.22), cornerRadius: w * 0.08),
                         with: .color(Color.remoteStand))
                let face = CGRect(x: w * 0.07, y: 0, width: w * 0.86, height: h * 0.84)
                let facePath = Path(roundedRect: face, cornerRadius: w * 0.3)
                ctx.fill(facePath, with: .color(Color.remoteFace))
                ctx.stroke(facePath, with: .color(Color.edge), lineWidth: w * 0.012)
                let r = w * 0.1
                for (b, rel) in RmDrawing.layout {
                    let c = CGPoint(x: face.minX + face.width * rel.x, y: face.minY + face.height * rel.y)
                    if b == target {
                        let rr = r * (1.1 + 0.7 * pulse)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .color(Color.brass.opacity(0.9 * (1 - pulse))), lineWidth: w * 0.02)
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .color(b == target ? Color.brass : Color.remoteButton))
                    if done.contains(b) && b != target {
                        let d = r * 0.28
                        let dc = CGPoint(x: c.x + r * 0.75, y: c.y - r * 0.75)
                        ctx.fill(Path(ellipseIn: CGRect(x: dc.x - d, y: dc.y - d, width: d * 2, height: d * 2)), with: .color(Color.okGreen))
                    }
                }
            }
        }
    }
}

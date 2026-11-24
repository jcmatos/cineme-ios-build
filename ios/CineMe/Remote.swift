import AVFoundation
import AVKit
import GameController
import SwiftUI
import UIKit

/// The five buttons of a ring remote like the JX-05 (a cross with one in the middle), pressed or held.
/// Same names as on Android, so the saved text means the same on both.
enum RemoteButton: String, CaseIterable, Identifiable {
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", center = "CENTER"
    case upHold = "UP_HOLD", downHold = "DOWN_HOLD", leftHold = "LEFT_HOLD", rightHold = "RIGHT_HOLD", centerHold = "CENTER_HOLD"

    var id: String { rawValue }
    static let presses: [RemoteButton] = [.up, .down, .left, .right, .center]
    static let holds: [RemoteButton] = [.upHold, .downHold, .leftHold, .rightHold, .centerHold]

    var isHold: Bool { RemoteButton.holds.contains(self) }
    /// The button itself (Up for Up held).
    var base: RemoteButton {
        guard let i = RemoteButton.holds.firstIndex(of: self) else { return self }
        return RemoteButton.presses[i]
    }
    /// The held version (Up held for Up).
    var held: RemoteButton {
        guard let i = RemoteButton.presses.firstIndex(of: self) else { return self }
        return RemoteButton.holds[i]
    }
    var name: String {
        switch base {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        default: return "Middle"
        }
    }
    var label: String { isHold ? name + " held" : name }
    var arrow: String {
        switch base {
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀\u{FE0E}"
        case .right: return "▶\u{FE0E}"
        default: return "●"
        }
    }
}

/// What a remote button can do. Android's tracking, photo mode and stand-by aren't on the iPhone yet.
/// Level and gimbal moves work once the app sets Remote.shared.handlers for them (hidden until then).
enum RemoteAction: String, CaseIterable, Identifiable {
    case record = "RECORD"
    case lens = "LENS"
    case manualFocus = "MANUAL_FOCUS"
    case focusNear = "FOCUS_NEAR"
    case focusFar = "FOCUS_FAR"
    case auto = "AUTO"
    case brighter = "BRIGHTER"
    case darker = "DARKER"
    case maps = "MAPS"
    case move = "MOVE"
    case nextMove = "NEXT_MOVE"
    case level = "LEVEL"
    case nothing = "NONE"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .record: return "Start / stop recording"
        case .lens: return "Change camera (0.5x, 1x, 2x...)"
        case .manualFocus: return "Manual focus on / off"
        case .focusNear: return "Focus closer"
        case .focusFar: return "Focus farther"
        case .auto: return "Auto light"
        case .brighter: return "Brighter"
        case .darker: return "Darker"
        case .maps: return "Maps (back: ‹ CineMe, top left)"
        case .move: return "Gimbal move on / off"
        case .nextMove: return "Next saved move"
        case .level: return "Level the horizon"
        case .nothing: return "Nothing"
        }
    }

    static func defaultFor(_ b: RemoteButton) -> RemoteAction {
        switch b {
        case .center: return .record
        case .up: return .brighter
        case .down: return .darker
        case .left: return .auto
        case .right: return .lens
        default: return .nothing
        }
    }
}

/// Bluetooth remotes on the iPhone arrive as a keyboard (arrow keys, Enter...) or as volume keys.
/// Keys come from GameController's keyboard (any key, whatever has focus) and, as a backup, from
/// UIKit key presses on [RemoteCatcherView]. Volume up / down, the Camera Control, the Action button
/// and AirPods come from AVCaptureEventInteraction (only while the camera runs).
///
/// A signal is "key:<HID usage>" (key:82 = up arrow), "cap:up" (volume up) or "cap:down" (volume
/// down, Camera Control, Action button, AirPods: iOS sends them all as one). Learned signals become
/// remote buttons ("key:82=UP;cap:up=UP_HOLD", as on Android). A button held about 0.6 s is its
/// "held" version, unless the remote sends something else when held (then that is learned).
/// Fake touches (some ring remotes swipe the screen) can't be told from a finger on iOS: not caught.
@MainActor
final class Remote: ObservableObject {
    static let shared = Remote()
    /// Held this long = the held version of the button.
    static let holdTime: Double = 0.6

    struct Press: Equatable { let button: RemoteButton; let at: Date }

    @Published private(set) var learned: [String: RemoteButton] = [:]
    @Published private(set) var actions: [RemoteButton: RemoteAction] = [:]
    /// The phone's own buttons, when no remote button was learned on them.
    @Published var volumeUp: RemoteAction { didSet { save(); refreshInteractions() } }
    @Published var volumeDown: RemoteAction { didSet { save(); refreshInteractions() } }
    /// Last remote button seen (the settings screen lights its row up).
    @Published private(set) var lastPress: Press?
    /// A keyboard-type device is connected (iOS gives no real name, only "Keyboard").
    @Published private(set) var keyboard: String?

    // Calibration: press (or hold) each button in [learning] in turn.
    @Published private(set) var learning: [RemoteButton]?
    @Published private(set) var step = 0
    @Published private(set) var got: [RemoteButton: String] = [:]
    @Published private(set) var learnMessage: String?

    /// Actions done elsewhere in the app (level, gimbal moves): set by the app at launch.
    var handlers: [RemoteAction: () -> Void] = [:] { didSet { objectWillChange.send() } }
    /// What the settings offer: the built-in actions, and the others once they have a handler.
    var offered: [RemoteAction] {
        RemoteAction.allCases.filter { ![.move, .nextMove, .level].contains($0) || handlers[$0] != nil }
    }

    private weak var camera: Camera?
    private var down: [String: Date] = [:]
    private var holdTasks: [String: Task<Void, Never>] = [:]
    private var consumed: Set<String> = []
    private var lockedUntil = Date.distantPast
    private let interactions = NSHashTable<AVCaptureEventInteraction>.weakObjects()
    private var fake = false

    private init() {
        let d = UserDefaults.standard
        volumeUp = RemoteAction(rawValue: d.string(forKey: "remoteVolUp") ?? "") ?? .record
        // Volume down shares iOS's "primary" button with the Camera Control and AirPods: record too.
        volumeDown = RemoteAction(rawValue: d.string(forKey: "remoteVolDown") ?? "") ?? .record
        learned = Remote.parseLearned(d.string(forKey: "remoteLearned") ?? "")
        actions = Remote.parseActions(d.string(forKey: "remoteActions") ?? "")
        watchKeyboards()
    }

    /// The camera the buttons drive. Call once at launch.
    func attach(_ camera: Camera) { self.camera = camera }

    var cameraRecording: Bool { camera?.recording ?? false }

    func action(_ b: RemoteButton) -> RemoteAction { actions[b] ?? RemoteAction.defaultFor(b) }

    func setAction(_ b: RemoteButton, _ a: RemoteAction) {
        actions[b] = a
        save()
    }

    // MARK: - signals

    /// Should a key press be kept from the rest of the app (learned, or calibrating)?
    func wants(_ sig: String) -> Bool { learning != nil || learned[sig] != nil }

    func signalDown(_ sig: String) {
        // The same press from a second source (GameController and UIKit both see keys): once.
        if let t = down[sig], Date().timeIntervalSince(t) < 5 { return }
        down[sig] = Date()
        consumed.remove(sig)
        holdTasks.removeValue(forKey: sig)?.cancel()
        guard learning == nil, let b = learned[sig], !b.isHold, waitsForHold(b) else { return }
        holdTasks[sig] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Remote.holdTime * 1_000_000_000))
            guard let self = self, !Task.isCancelled, self.down[sig] != nil else { return }
            self.consumed.insert(sig)
            self.fire(b.held)
        }
    }

    /// The press ended: does its action now (or learns it). Returns the action done, if any.
    @discardableResult
    func signalUp(_ sig: String) -> RemoteAction? {
        guard let t = down.removeValue(forKey: sig) else { return nil }
        holdTasks.removeValue(forKey: sig)?.cancel()
        if consumed.remove(sig) != nil { return nil }   // its held action already ran
        if learning != nil {
            learn(sig, held: Date().timeIntervalSince(t))
            return nil
        }
        if let b = learned[sig] { return fire(b) }
        let a: RemoteAction? = sig == "cap:up" ? volumeUp : sig == "cap:down" ? volumeDown : nil
        if let a = a { perform(a) }
        return a
    }

    func signalCancel(_ sig: String) {
        down.removeValue(forKey: sig)
        holdTasks.removeValue(forKey: sig)?.cancel()
        consumed.remove(sig)
    }

    /// A press waits for its release only when its held version does something of its own.
    private func waitsForHold(_ b: RemoteButton) -> Bool {
        action(b.held) != .nothing && !learned.values.contains(b.held)
    }

    @discardableResult
    private func fire(_ b: RemoteButton) -> RemoteAction {
        lastPress = Press(button: b, at: Date())
        let a = action(b)
        perform(a)
        return a
    }

    /// Does what a button is set to, like Android's doAction.
    func perform(_ a: RemoteAction) {
        guard let c = camera else { return }
        // The library is on screen: the remote doesn't drive the camera behind it.
        if LibraryRemote.shared.isOpen { return }
        switch a {
        case .record:
            c.toggleRecord()
        case .lens:
            if c.recording { say("Not while recording") } else { c.nextLens() }
        case .manualFocus:
            c.autoFocus.toggle()
            c.setFocus()
            say(c.autoFocus ? "Autofocus" : "Manual focus")
        case .focusNear, .focusFar:
            c.autoFocus = false
            c.focus = min(max(c.focus + (a == .focusFar ? 0.03 : -0.03), 0), 1)
            c.setFocus()
            say("Focus \(Int((c.focus * 100).rounded()))")
        case .auto:
            c.autoOnce()
        case .brighter:
            c.exposureStep(1)
        case .darker:
            c.exposureStep(-1)
        case .maps:
            // iOS can open Maps but never come back by itself: the way back is "‹ CineMe" at the
            // top left of Maps. Leaving stops the camera, so not while recording.
            if c.recording { say("Not while recording") } else { openMaps() }
        case .move, .nextMove, .level:
            if c.recording && a != .level { say("Not while recording") } else { handlers[a]?() }
        case .nothing:
            break
        }
    }

    private func say(_ m: String) { camera?.message = m }

    /// Google Maps if it's installed, else Apple Maps. open() needs no plist entry (canOpenURL would).
    private func openMaps() {
        guard let google = URL(string: "comgooglemaps://"), let apple = URL(string: "maps://") else { return }
        UIApplication.shared.open(google, options: [:]) { ok in
            if !ok {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { UIApplication.shared.open(apple, options: [:], completionHandler: nil) }
                }
            }
        }
    }

    // MARK: - phone buttons (AVCaptureEventInteraction)

    func register(_ i: AVCaptureEventInteraction) {
        interactions.add(i)
        i.isEnabled = capturesButtons
    }

    /// Off when nothing uses the volume buttons: they set the volume again.
    private var capturesButtons: Bool {
        learning != nil || volumeUp != .nothing || volumeDown != .nothing || learned.keys.contains { $0.hasPrefix("cap:") }
    }

    private func refreshInteractions() {
        let on = capturesButtons
        for i in interactions.allObjects { i.isEnabled = on }
    }

    // MARK: - keyboards (GameController)

    private func watchKeyboards() {
        let nc = NotificationCenter.default
        _ = nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Remote.shared.attachKeyboard() }
        }
        _ = nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Remote.shared.attachKeyboard() }
        }
        attachKeyboard()
    }

    private func attachKeyboard() {
        if fake { return }
        let kb = GCKeyboard.coalesced
        keyboard = kb.map { $0.vendorName ?? "Keyboard" }
        kb?.keyboardInput?.keyChangedHandler = { _, _, code, pressed in
            let sig = "key:\(code.rawValue)"
            // GameController calls on the main queue.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if pressed { Remote.shared.signalDown(sig) } else { _ = Remote.shared.signalUp(sig) }
                }
            }
        }
    }

    // MARK: - calibration

    var target: RemoteButton? {
        guard let order = learning, step < order.count else { return nil }
        return order[step]
    }

    func startLearning(_ order: [RemoteButton]) {
        for t in holdTasks.values { t.cancel() }
        holdTasks = [:]; down = [:]; consumed = []
        got = [:]; step = 0; learnMessage = nil
        learning = order
        refreshInteractions()
    }

    func stopLearning() {
        guard learning != nil else { return }
        learning = nil
        refreshInteractions()
    }

    func skip() {
        guard let t = target else { return }
        learnMessage = "\(t.label) skipped"
        advance()
    }

    func back() {
        guard let order = learning, step > 0 else { return }
        step -= 1
        got.removeValue(forKey: order[step])
        learnMessage = nil
    }

    private func learn(_ sig: String, held: Double) {
        guard let t = target, Date() >= lockedUntil else { return }
        if let clash = got.first(where: { $0.value == sig && $0.key != t }) {
            learnMessage = "That's the same as \(clash.key.label). Press \(t.label) again, or Skip."
            return
        }
        if t.isHold, learned[sig] == t.base {
            // Held, it sends the same key as pressed: told apart by how long it's held. Nothing to learn.
            learnMessage = held >= Remote.holdTime
                ? "\(t.label): same key, held longer. That works."
                : "\(t.label) = a short press. Hold it about 1 s, or Skip."
            if held >= Remote.holdTime { advance() }
            return
        }
        if let other = learned[sig], !(learning ?? []).contains(other) {
            learnMessage = "Same as \(other.label). Press \(t.label) again, or Skip."
            return
        }
        got[t] = sig
        learnMessage = "\(t.label) = \(Remote.describe(sig))"
        advance()
    }

    private func advance() {
        guard let order = learning else { return }
        // One press can send a burst: don't let it fill the next step too.
        lockedUntil = Date().addingTimeInterval(0.5)
        step += 1
        guard step >= order.count else { return }
        // Keeps what the other calibration learned (presses / holds); these buttons are replaced.
        var m = learned.filter { !order.contains($0.value) && !got.values.contains($0.key) }
        for (b, s) in got { m[s] = b }
        learned = m
        save()
        learning = nil
        refreshInteractions()
        say("Remote learned")
    }

    // MARK: - saved text (same format as Android)

    private func save() {
        if fake { return }
        let d = UserDefaults.standard
        d.set(learned.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ";"), forKey: "remoteLearned")
        d.set(actions.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ";"), forKey: "remoteActions")
        d.set(volumeUp.rawValue, forKey: "remoteVolUp")
        d.set(volumeDown.rawValue, forKey: "remoteVolDown")
    }

    private static func pairs(_ s: String) -> [(String, String)] {
        s.split(separator: ";").compactMap { e in
            guard let i = e.lastIndex(of: "="), i != e.startIndex else { return nil }
            return (String(e[..<i]), String(e[e.index(after: i)...]))
        }
    }

    static func parseLearned(_ s: String) -> [String: RemoteButton] {
        var m: [String: RemoteButton] = [:]
        for (k, v) in pairs(s) { if let b = RemoteButton(rawValue: v) { m[k] = b } }
        return m
    }

    static func parseActions(_ s: String) -> [RemoteButton: RemoteAction] {
        var m: [RemoteButton: RemoteAction] = [:]
        for (k, v) in pairs(s) { if let b = RemoteButton(rawValue: k), let a = RemoteAction(rawValue: v) { m[b] = a } }
        return m
    }

    /// Human text for a signal: "key:82" -> "Up arrow key", "cap:up" -> "Volume up".
    static func describe(_ sig: String) -> String {
        if sig == "cap:up" { return "Volume up" }
        if sig == "cap:down" { return "Volume down / Camera Control" }
        guard sig.hasPrefix("key:"), let n = Int(sig.dropFirst(4)) else { return sig }
        let names: [Int: String] = [
            40: "Enter", 41: "Escape", 42: "Backspace", 43: "Tab", 44: "Space",
            74: "Home", 75: "Page up", 77: "End", 78: "Page down",
            79: "Right arrow", 80: "Left arrow", 81: "Down arrow", 82: "Up arrow",
            88: "Keypad enter", 127: "Mute", 128: "Volume up", 129: "Volume down",
        ]
        if let name = names[n] { return name + " key" }
        if (4...29).contains(n), let u = UnicodeScalar(UInt32(61 + n)) { return "\(Character(u)) key" }   // 4 = A
        if (30...38).contains(n) { return "\(n - 29) key" }
        if n == 39 { return "0 key" }
        if (58...69).contains(n) { return "F\(n - 57) key" }
        return "Key \(n)"
    }

    // MARK: - screenshot runs

    /// Shot.screen == "remote": a learned remote, a row lit, a keyboard connected.
    func fakeForShots() {
        fake = true
        learned = ["key:82": .up, "key:81": .down, "key:80": .left, "key:79": .right, "key:40": .center, "cap:up": .upHold]
        actions = [.upHold: .lens, .downHold: .maps]
        keyboard = "Keyboard"
        lastPress = Press(button: .right, at: Date())
    }
}

// MARK: - the view that catches the buttons

/// Put behind the camera screen (and in Settings > Remote, for calibrating). Catches the volume
/// buttons / Camera Control (AVCaptureEventInteraction, only while the camera runs) and, as first
/// responder, keyboard keys the remote sends.
struct RemoteCatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> RemoteCatcherView { RemoteCatcherView() }
    func updateUIView(_ uiView: RemoteCatcherView, context: Context) {}
}

final class RemoteCatcherView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Primary: volume down, Camera Control, Action button, AirPods. Secondary: volume up.
        let i = AVCaptureEventInteraction(primary: { e in
            MainActor.assumeIsolated { RemoteCatcherView.capture("cap:down", e) }
        }, secondary: { e in
            MainActor.assumeIsolated { RemoteCatcherView.capture("cap:up", e) }
        })
        addInteraction(i)
        Remote.shared.register(i)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func capture(_ sig: String, _ e: AVCaptureEvent) {
        let r = Remote.shared
        switch e.phase {
        case .began:
            r.signalDown(sig)
        case .ended:
            let stopping = r.cameraRecording
            // AirPods (iOS 26+): the app plays the record sound in the AirPods itself.
            let done = r.signalUp(sig)
            if done == .record {
                if #available(iOS 26.0, *) {
                    if e.shouldPlaySound { _ = e.play(stopping ? .endVideoRecording : .beginVideoRecording) }
                }
            }
        case .cancelled:
            r.signalCancel(sig)
        @unknown default:
            break
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handle(presses) { Remote.shared.signalDown($0) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handle(presses) { _ = Remote.shared.signalUp($0) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = handle(presses) { Remote.shared.signalCancel($0) }
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Learned keys (or any, while calibrating) go to the remote; the rest are returned.
    private func handle(_ presses: Set<UIPress>, _ f: (String) -> Void) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for p in presses {
            if let k = p.key, Remote.shared.wants("key:\(k.keyCode.rawValue)") { f("key:\(k.keyCode.rawValue)") } else { rest.insert(p) }
        }
        return rest
    }
}

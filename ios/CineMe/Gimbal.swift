import CoreBluetooth
import Foundation
import SwiftUI

// The Zhiyun Smooth-Q over Bluetooth: the same protocol as the Android app (ZhiyunProtocol.kt /
// ZhiyunBle.kt), ported to CoreBluetooth.
//  - Phone -> gimbal on ...600: [06][codeHi][codeLo][valHi][valLo][crcHi][crcLo], CRC-16/XMODEM over bytes 0..4.
//  - Gimbal -> phone on ...601: the same 7-byte frames (a stream, cut every 7 bytes); on ...610: 4-byte frames.
//  - Buttons: code with low byte 0x20, value [type:4][group:4][event:4][key:4]. Key 6 record, 7 slider T,
//    8 slider W, 0 = "no key" (ignored). Event 0 down, 2 released after a hold, 3 click.
//  - Joystick: 0x1001 tilt, 0x1002 roll, 0x1003 pan, 0x0800 = still, resent every 100 ms.

enum GimbalState: String { case off = "Off", scanning = "Scanning", connecting = "Connecting", connected = "Connected" }

/// SHUTTER = record button click. SLIDER_W / _T = a short push of the slider. HOLD_W / _T = held half a second.
enum GimbalEvent { case shutter, sliderW, sliderT, holdW, holdT, release, mode }

enum Zhiyun {
    static let charWrite = CBUUID(string: "d44bc439-abfd-45a2-b575-925416129600")
    static let charData = CBUUID(string: "d44bc439-abfd-45a2-b575-925416129601")
    static let charCmd = CBUUID(string: "d44bc439-abfd-45a2-b575-925416129610")
    static let companyID: UInt16 = 0x0509
    static let codeTilt = 0x1001, codeRoll = 0x1002, codePan = 0x1003
    static let codeModeRead = 0x0127, codeModeSet = 0x8127
    static let modeLock = 1, modeRoll = 2
    static let center = 0x0800

    static func frame(_ code: Int, _ value: Int) -> Data {
        var f: [UInt8] = [6, UInt8((code >> 8) & 0xff), UInt8(code & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff), 0, 0]
        let crc = crc16(f, 5)
        f[5] = UInt8(crc >> 8); f[6] = UInt8(crc & 0xff)
        return Data(f)
    }

    /// CRC-16/XMODEM: poly 0x1021, init 0.
    static func crc16(_ b: [UInt8], _ len: Int) -> Int {
        var crc = 0
        for i in 0..<len {
            crc ^= Int(b[i]) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1) }
            crc &= 0xffff
        }
        return crc
    }

    /// -1..1 -> 0..4095 around 0x0800.
    static func speed(_ x: Float) -> Int { min(4095, max(0, Int(Float(center) + max(-1, min(1, x)) * 2047))) }

    static func looksLike(_ name: String) -> Bool {
        name.range(of: "smooth|zhiyun|^zy|crane|weebill", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

final class Gimbal: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state: GimbalState = .off
    @Published var name: String? = nil
    @Published var log: [String] = []
    /// The last key, with when, so the screen can flash it.
    @Published var lastKey: (GimbalEvent, Date)? = nil
    /// Follow speed 1 (very smooth) .. 5 (fast), sent on every connect.
    @Published var follow: Int = UserDefaults.standard.object(forKey: "gimbalFollow") as? Int ?? 3
    @Published var joystickSpeed: Int = UserDefaults.standard.object(forKey: "joystickSpeed") as? Int ?? 3

    var onEvent: (GimbalEvent) -> Void = { _ in }
    /// Also told of every key (the camera screen: MODE stops tracking and moves), next to [onEvent].
    var onEventAlso: (GimbalEvent) -> Void = { _ in }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var wanted = false
    private var savedID: UUID? = UserDefaults.standard.string(forKey: "gimbalID").flatMap(UUID.init(uuidString:))
    private var buf601: [UInt8] = []
    private var queue: [Data] = []
    private var mode = -1
    private var modeWrittenAt = Date.distantPast

    // Keys (as on Android). Main thread.
    private var recordDownAt: Date? = nil
    private var sliderDownAt: Date? = nil
    private var sliderKey = 0
    private var comboUsed = false
    private var hold: DispatchWorkItem? = nil

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() { wanted = true; if central.state == .poweredOn { scan() } }

    func stop() {
        wanted = false
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = .off
    }

    /// Long press on the G: drop the link and look again.
    func reconnect() { stop(); start() }

    private func add(_ line: String) {
        let t = String(format: "%6.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100))
        log = Array((log + ["\(t) \(line)"]).suffix(300))
    }

    // MARK: - scan and connect

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        add("Bluetooth \(c.state == .poweredOn ? "on" : "not ready (\(c.state.rawValue))")")
        if c.state == .poweredOn && wanted { scan() }
    }

    private func scan() {
        // The gimbal we used last, straight away if iOS still knows it.
        if let id = savedID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        state = .scanning
        add("scanning")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        var zhiyun = false
        if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            zhiyun = UInt16(m[m.startIndex]) | (UInt16(m[m.startIndex + 1]) << 8) == Zhiyun.companyID
        }
        guard zhiyun || Zhiyun.looksLike(name) else { return }
        add("found \(name.isEmpty ? "Zhiyun gimbal" : name)")
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        add("connecting")
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        name = p.name
        savedID = p.identifier
        UserDefaults.standard.set(p.identifier.uuidString, forKey: "gimbalID")
        add("connected, mtu \(p.maximumWriteValueLength(for: .withoutResponse) + 3)")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        add("couldn't connect: \(error?.localizedDescription ?? "?")")
        retry()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        add("disconnected")
        state = .off
        writeChar = nil
        buf601.removeAll(); queue.removeAll()
        moving = false
        retry()
    }

    private func retry() {
        guard wanted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.wanted && self.state == .off { self.scan() } }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true, for: ch) }
            if ch.uuid == Zhiyun.charWrite { writeChar = ch }
        }
        if writeChar != nil && state != .connected {
            state = .connected
            add("ready")
            send(Zhiyun.frame(0x0104, 0))
            send(Zhiyun.frame(Zhiyun.codeModeRead, 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.setFollow() }
            // Reconnected while the phone was in control (tracking, a move): its mode again.
            if savedMode >= 0 { sendRaw(Zhiyun.codeModeSet, controlMode); startPoll() }
        }
    }

    // MARK: - writing

    private func send(_ d: Data) {
        queue.append(d)
        pump()
    }

    private func pump() {
        guard let p = peripheral, let ch = writeChar else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        while !queue.isEmpty && (type == .withResponse || p.canSendWriteWithoutResponse) {
            p.writeValue(queue.removeFirst(), for: ch, type: type)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { pump() }

    func sendRaw(_ code: Int, _ value: Int) {
        if code == Zhiyun.codeModeSet { modeWrittenAt = Date() }
        send(Zhiyun.frame(code, value))
    }

    /// Follow speed and joystick speed, the way ZY Play sends them (the Android app's setFollow).
    func setFollow() {
        guard state == .connected else { return }
        UserDefaults.standard.set(follow, forKey: "gimbalFollow")
        UserDefaults.standard.set(joystickSpeed, forKey: "joystickSpeed")
        let l = max(1, min(5, follow))
        let k = Float(max(0, l - 2)) / 3
        func mix(_ slow: Int, _ fast: Int) -> Int { l == 1 ? Int(Float(slow) * 0.12) : Int(Float(slow) + Float(fast - slow) * k) }
        let a = [mix(8000, 12000), mix(8000, 12000), mix(6000, 12000)]
        let b = [mix(2500, 10000), mix(2500, 10000), mix(4500, 10000)]
        let c = [50, 100, 150, 200, 260][max(1, min(5, joystickSpeed)) - 1]
        let set: [(Int, Int)] = [(0x815e, a[0]), (0x815f, a[1]), (0x8160, a[2]), (0x8164, b[0]), (0x8165, b[1]), (0x8166, b[2]),
                                 (0x8161, c), (0x8162, c), (0x8163, c), (0x815b, 200), (0x815c, 500), (0x815d, 500), (0x8167, 0), (0xc105, 0xa151)]
        for (code, v) in set { send(Zhiyun.frame(code, v)) }
        add("follow \(follow), joystick \(joystickSpeed)")
    }

    // MARK: - moving (level, moves, time-lapse steps and tracking use this)

    private var moving = false
    private var movePan: Float = 0
    private var moveTilt: Float? = nil
    /// Roll joystick instead of pan + tilt (the speed is in [movePan]), as on Android (rawCode = roll).
    private var moveRoll = false
    private var stopsLeft = 0

    /// Joystick -1..1 (pan + = right, tilt + = up; tilt nil = pan only), resent every 100 ms.
    func move(pan: Float, tilt: Float?) {
        guard state == .connected else { return }
        movePan = pan; moveTilt = tilt; moveRoll = false; stopsLeft = 0
        if !moving { moving = true; tick() }
    }

    /// Roll joystick -1..1 (the level). Still all three joystick frames, like ZY Play: the gimbal ignores a lone one.
    /// Roll only obeys in mode 2 ([takeControl] with Zhiyun.modeRoll).
    func roll(_ speed: Float) {
        guard state == .connected else { return }
        movePan = speed; moveTilt = nil; moveRoll = true; stopsLeft = 0
        if !moving { moving = true; tick() }
    }

    /// Back to centre (sent twice, in case one is lost), then the loop ends.
    func stopMove() {
        guard moving else { return }
        movePan = 0; moveTilt = moveTilt.map { _ in 0 }; stopsLeft = 2
    }

    private func tick() {
        guard moving else { return }
        var all = Data()
        if moveRoll {
            all.append(Zhiyun.frame(Zhiyun.codeTilt, Zhiyun.center))
            all.append(Zhiyun.frame(Zhiyun.codeRoll, Zhiyun.speed(movePan)))
            all.append(Zhiyun.frame(Zhiyun.codePan, Zhiyun.center))
        } else {
            all.append(Zhiyun.frame(Zhiyun.codeTilt, Zhiyun.speed(moveTilt ?? 0)))
            all.append(Zhiyun.frame(Zhiyun.codeRoll, Zhiyun.center))
            all.append(Zhiyun.frame(Zhiyun.codePan, Zhiyun.speed(movePan)))
        }
        if let p = peripheral, all.count <= p.maximumWriteValueLength(for: .withoutResponse) { send(all) }
        else { stride(from: 0, to: all.count, by: 7).forEach { send(all.subdata(in: $0..<($0 + 7))) } }
        if stopsLeft > 0 { stopsLeft -= 1; if stopsLeft == 0 { moving = false; return } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.tick() }
    }

    // MARK: - phone in control (the Android app's takeControl / releaseControl)

    /// Mode to go back to after [takeControl], or -1 when the phone isn't in control.
    private var savedMode = -1
    /// Mode set by [takeControl] (sent again after a reconnect).
    private var controlMode = Zhiyun.modeLock
    private var pollGen = 0

    /// Mode for moving tilt from the phone: lock stays lock, anything else = 0 (pan follows the handle).
    var modeForTilt: Int { mode == Zhiyun.modeLock ? Zhiyun.modeLock : 0 }

    /// Tracking uses lock (the only mode where pan obeys the phone); roll only obeys in mode 2.
    func takeControl(_ m: Int = Zhiyun.modeLock) {
        // Mode 2 is only the phone's roll mode (tilt follows the handle in it): never "go back" to it.
        if savedMode < 0 { savedMode = (0...1).contains(mode) ? mode : 0 }
        controlMode = m
        guard state == .connected else { return }
        sendRaw(Zhiyun.codeModeSet, m)
        startPoll()
    }

    /// Back to the mode the gimbal was in, once the stop frames are out.
    func releaseControl() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard self.savedMode >= 0, !self.moving else { return }
            self.pollGen += 1
            if self.state == .connected { self.sendRaw(Zhiyun.codeModeSet, self.savedMode) }
            self.savedMode = -1
        }
    }

    /// The gimbal doesn't announce a MODE press, so while the phone is in control ask for the mode
    /// every second: a change we didn't make comes back as [GimbalEvent.mode].
    private func startPoll() {
        pollGen += 1
        let gen = pollGen
        func poll() {
            guard gen == pollGen, savedMode >= 0, state == .connected else { return }
            send(Zhiyun.frame(Zhiyun.codeModeRead, 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { poll() }
    }

    // MARK: - reading

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        let b = [UInt8](v)
        if ch.uuid == Zhiyun.charData {
            buf601 += b
            while buf601.count >= 7 {
                let f = Array(buf601.prefix(7)); buf601.removeFirst(7)
                handle(Int(f[1]) << 8 | Int(f[2]), Int(f[3]) << 8 | Int(f[4]))
            }
        } else if ch.uuid == Zhiyun.charCmd {
            var i = 0
            while i + 4 <= b.count { handle(Int(b[i]) << 8 | Int(b[i + 1]), Int(b[i + 2]) << 8 | Int(b[i + 3])); i += 4 }
        }
    }

    private func handle(_ code: Int, _ value: Int) {
        if code == 0x0104 { add("firmware \(value >> 8).\(value & 0xff)") }
        if code == Zhiyun.codeModeRead || code == Zhiyun.codeModeSet {
            if mode >= 0 && value != mode && Date().timeIntervalSince(modeWrittenAt) > 1.5 { emit(.mode) }
            mode = value
        }
        guard code & 0xff == 0x20 else { return }
        let key = value & 0xf
        guard key != 0 else { return }
        let event = (value >> 4) & 0xf
        add("key \(key) event \(event)")
        switch key {
        case 6:
            if event == 0 { recordDownAt = Date() }
            if event == 3 || event == 2 {
                recordDownAt = nil
                if !comboUsed && event == 3 { emit(.shutter) }
                if sliderDownAt == nil { comboUsed = false }
            }
        case 7, 8:
            let w = key == 8
            if event == 0 {
                sliderKey = key; sliderDownAt = Date()
                if recordDownAt != nil { comboUsed = true; return }
                let item = DispatchWorkItem { [weak self] in self?.hold = nil; self?.emit(w ? .holdW : .holdT) }
                hold = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
            } else if event == 2 || event == 3 {
                sliderDownAt = nil
                if let h = hold { h.cancel(); hold = nil; if !comboUsed { emit(w ? .sliderW : .sliderT) } }
                else { emit(.release) }
                if recordDownAt == nil { comboUsed = false }
            }
        default:
            break
        }
    }

    private func emit(_ e: GimbalEvent) {
        lastKey = (e, Date())
        onEvent(e)
        onEventAlso(e)
    }
}

// MARK: - screens (Android look: CameraScreen.kt GimbalBadge :1001, GimbalSheet :2257, Settings > Gimbal :2003)

extension Gimbal {
    /// "Scanning", or the gimbal's name when connected.
    var stateText: String { state == .connected ? (name ?? "Connected") : state.rawValue }

    /// Follow / joystick speed for a slider: sent to the gimbal (and saved) on every change.
    var followBinding: Binding<Int> {
        Binding(get: { self.follow }, set: { v in
            guard v != self.follow else { return }
            self.follow = v
            self.setFollow()
        })
    }
    var joystickBinding: Binding<Int> {
        Binding(get: { self.joystickSpeed }, set: { v in
            guard v != self.joystickSpeed else { return }
            self.joystickSpeed = v
            self.setFollow()
        })
    }

    /// A key tapped on the screen: as if pressed on the gimbal (Android's simulate).
    func simulate(_ e: GimbalEvent) {
        lastKey = (e, Date())
        onEvent(e)
    }

    /// Joystick test: one second that way, at 30% speed (Android's nudge).
    func nudge(pan: Float, tilt: Float) {
        move(pan: pan, tilt: tilt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.stopMove() }
    }
}

/// The G at the top right (Android GimbalBadge): a 22dp circle, Live when connected, Red when not,
/// "G" white 12sp w600, 6dp tap margin. Tap: the gimbal sheet. Long press: look again.
struct GimbalBadge: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var gimbal: Gimbal
    let onTap: () -> Void
    var body: some View {
        CineGimbalBadge(connected: gimbal.state == .connected)
            .padding(s(6))
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture { gimbal.reconnect() }
    }
}

/// The gimbal sheet ("Pairing and log", Android GimbalSheet): full screen, camera scale. Landscape:
/// controls in a 300dp column left, the Bluetooth log right; portrait: controls on top, log under.
struct GimbalPanel: View {
    @ObservedObject var gimbal: Gimbal
    let onClose: () -> Void
    @State private var lit: GimbalEvent? = nil
    private let s = CineScale.cam

    init(gimbal: Gimbal, onClose: @escaping () -> Void) {
        self.gimbal = gimbal
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { g in
            let portrait = g.size.height > g.size.width
            let safe = PaneSafeArea.overlap(g.frame(in: .global))
            if portrait {
                let avail = max(0, g.size.height - s(36) - s(14) - safe.top - safe.bottom)
                VStack(spacing: s(14)) {
                    controls.frame(height: avail * 0.55)
                    logBox
                }
                .padding(.horizontal, s(24)).padding(.vertical, s(18))
                .padding(safe)
            } else {
                HStack(spacing: s(28)) {
                    controls.frame(width: s(300))
                    logBox
                }
                .padding(.horizontal, s(36)).padding(.vertical, s(18))
                .padding(safe)
            }
        }
        .background(Color.sheet.ignoresSafeArea().onTapGesture {})
        .cineScale(.cam)
        .cineDefaultText(.cam)
        .onChange(of: gimbal.lastKey?.1) { _, _ in
            guard let k = gimbal.lastKey else { return }
            lit = k.0
            let at = k.1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if gimbal.lastKey?.1 == at { lit = nil }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Gimbal").font(s.font(24, .medium)).foregroundStyle(Color.ivory)
                Spacer(minLength: s(8))
                CinePill("Close", action: onClose)
            }
            Text(gimbal.stateText).font(s.font(15)).foregroundStyle(Color.dim).padding(.vertical, s(6))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    PaneSliderRow("Follow speed", value: gimbal.followBinding, range: 1...5, low: "Smooth", high: "Fast")
                    PaneSliderRow("Joystick speed", value: gimbal.joystickBinding, range: 1...5, low: "Slow", high: "Fast")
                    CineNote("Record: start / stop (also stops a time-lapse). Slider: brighter (W) / darker (T). Slider held: W = next lens, T = Auto light. MODE: stops tracking.")
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: s(6)) {
                CinePill("Search again") { gimbal.reconnect() }
                // Light up when the gimbal key arrives; tapping one runs it as if pressed on the gimbal.
                HStack(spacing: s(6)) {
                    keyPill("Shutter", .shutter)
                    keyPill("W", .sliderW)
                    keyPill("T", .sliderT)
                }
                FlowRow(spacing: s(6), lineSpacing: s(6)) {
                    CinePill("◄ Pan") { gimbal.nudge(pan: -0.3, tilt: 0) }
                    CinePill("Pan ►") { gimbal.nudge(pan: 0.3, tilt: 0) }
                    CinePill("Tilt ▲") { gimbal.nudge(pan: 0, tilt: 0.3) }
                    CinePill("Tilt ▼") { gimbal.nudge(pan: 0, tilt: -0.3) }
                }
            }
            .padding(.top, s(6))
        }
    }

    private func keyPill(_ label: String, _ e: GimbalEvent) -> some View {
        CinePill(selected: lit == e, action: { gimbal.simulate(e) }) {
            Text(label).foregroundStyle(lit == e ? Color.brass : Color.ivory)
        }
    }

    /// The log: r12 Drum box, 1dp Edge, padding 12, monospace 12sp, newest at the bottom.
    private var logBox: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(gimbal.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: s(12), design: .monospaced)).foregroundStyle(Color.logText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .padding(s(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .plate(cineRect(s(12)), fill: Color.drum, border: Color.edge)
    }
}

/// Settings > Gimbal (Android :2003): status, follow and joystick speed, the keys, the sheet.
struct GimbalSettingsPage: View {
    @Environment(\.cineScale) private var s
    @ObservedObject var gimbal: Gimbal
    let onPairing: () -> Void

    var body: some View {
        PaneValueRow("Status", gimbal.stateText)
        PaneSliderRow("Follow speed", value: gimbal.followBinding, range: 1...5, low: "Smooth", high: "Fast")
        PaneSliderRow("Joystick speed", value: gimbal.joystickBinding, range: 1...5, low: "Slow", high: "Fast")
        CineNote("Sent to the gimbal when it connects, and at once while it is connected.")
        CineNote("Record: start / stop (also stops a time-lapse). Slider: brighter (W) / darker (T). Slider held: W = next lens, T = Auto light. MODE: stops tracking.")
        FlowRow(spacing: s(6), lineSpacing: s(6)) {
            CinePill("Pairing and log", action: onPairing)
            CinePill("Search again") { gimbal.reconnect() }
        }
        .padding(.top, s(6))
    }
}

/// The gimbal sheet on its own (old `.sheet { GimbalSheet(gimbal:) }` callers).
struct GimbalSheet: View {
    @ObservedObject var gimbal: Gimbal
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GimbalPanel(gimbal: gimbal) { dismiss() }
    }
}


import AVFoundation
import CoreLocation
import ImageIO
import SwiftUI

/// Where the phone is, for the place in clips and photos (to group footage by place when editing).
/// While CineMe is open it follows the position (updates only after 10 m or more); a few metres is
/// plenty. Settings > Save to > Place. Port of the Android Locator.kt.
/// start() / stop() on the main thread; current() and the metadata from any thread.
final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()
    /// Older than this: not used (the phone may have moved far).
    static let maxAge: TimeInterval = 10 * 60
    static let key = "location"

    /// The setting (on by default, as on Android).
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private let lock = NSLock()
    private var last: CLLocation?
    private var manager: CLLocationManager?

    /// Starts following the position; asks for permission the first time. Main thread.
    func start() {
        guard Locator.enabled, manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        m.distanceFilter = 10
        m.activityType = .other
        manager = m
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: m.startUpdatingLocation()
        default: break
        }
        if let l = m.location { keep(l) }
    }

    /// Main thread.
    func stop() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
    }

    /// The latest position, if recent enough (and the setting is on).
    func current() -> CLLocation? {
        guard Locator.enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let l = last, l.horizontalAccuracy >= 0, -l.timestamp.timeIntervalSinceNow < Locator.maxAge else { return nil }
        return l
    }

    private func keep(_ l: CLLocation) {
        lock.lock(); last = l; lock.unlock()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if manager === m { m.startUpdatingLocation() }
        default:
            break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { keep(l) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // No fix yet (indoors): keep the last one; it ages out by itself.
    }

    // MARK: in the files

    /// ISO 6709 as the iPhone camera writes it: "+45.5017-073.5673+035.000/".
    static func iso6709(_ l: CLLocation) -> String {
        var s = String(format: "%+08.4f%+09.4f", l.coordinate.latitude, l.coordinate.longitude)
        if l.verticalAccuracy > 0 { s += String(format: "%+08.3f", l.altitude) }
        return s + "/"
    }

    /// For AVCaptureMovieFileOutput.metadata (and AVAssetWriter.metadata): the place, so Photos and
    /// editors show where the clip was filmed. Empty when off or not known.
    func movieMetadata() -> [AVMetadataItem] {
        guard let l = current() else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        item.value = Locator.iso6709(l) as NSString
        return [item]
    }

    /// The EXIF GPS block for a photo (HEIC, JPEG, DNG).
    static func gps(_ l: CLLocation) -> [String: Any] {
        let lat = l.coordinate.latitude, lon = l.coordinate.longitude
        let utcTime = DateFormatter(), utcDate = DateFormatter()
        for f in [utcTime, utcDate] { f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC") }
        utcTime.dateFormat = "HH:mm:ss.SS"
        utcDate.dateFormat = "yyyy:MM:dd"
        var g: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(lat),
            kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(lon),
            kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
            kCGImagePropertyGPSTimeStamp as String: utcTime.string(from: l.timestamp),
            kCGImagePropertyGPSDateStamp as String: utcDate.string(from: l.timestamp),
            kCGImagePropertyGPSHPositioningError as String: l.horizontalAccuracy,
        ]
        if l.verticalAccuracy > 0 {
            g[kCGImagePropertyGPSAltitude as String] = abs(l.altitude)
            g[kCGImagePropertyGPSAltitudeRef as String] = l.altitude >= 0 ? 0 : 1
        }
        return g
    }
}

/// Settings row: the place in clips and photos. Turning it on asks for permission.
struct LocationToggle: View {
    @AppStorage(Locator.key) private var on = true
    var body: some View {
        Toggle("Place (GPS) in clips and photos", isOn: $on)
            .onChange(of: on) { _, v in
                if v { Locator.shared.start() } else { Locator.shared.stop() }
            }
    }
}

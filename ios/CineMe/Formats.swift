import AVFoundation

// What a clip is recorded as. The iPhone 18 Pro (Apple's spec page, Nov 2026):
// - 4K at 24, 25, 30, 60, and 100 / 120 fps on the Fusion Main camera; 1080p at 25, 30, 60, 120, 240 (slow motion); 720p30.
// - HEVC, H.264, ProRes, ProRes RAW. ProRes 4K120 only to an external drive.
// - Dolby Vision HDR (HLG), Apple Log 2 (in HEVC or ProRes), ACES.
// The formats below are only offered when the camera reports one that can do them.

/// The picture's colour: what the camera hands the encoder.
enum Look: String, CaseIterable, Identifiable {
    case sdr = "SDR"
    case hdr = "HDR (Dolby Vision)"
    case log2 = "Apple Log 2"
    case log = "Apple Log"
    var id: String { rawValue }

    /// AVCaptureColorSpace raw values: sRGB 0, P3 1, HLG_BT2020 2, appleLog 3, appleLog2 4 (iOS 26 SDK).
    /// Raw numbers, so this builds on any SDK; the camera says which it has.
    var colorSpaceRaw: Int {
        switch self {
        case .sdr: return 0
        case .hdr: return 2
        case .log: return 3
        case .log2: return 4
        }
    }

    /// HDR and Log need a 10-bit format.
    var tenBit: Bool { self != .sdr }
}

enum Codec: String, CaseIterable, Identifiable {
    case hevc = "HEVC"
    case h264 = "H.264"
    case proRes422HQ = "ProRes 422 HQ"
    case proRes422 = "ProRes 422"
    case proRes422LT = "ProRes 422 LT"
    case proRes422Proxy = "ProRes 422 Proxy"
    case proResRAW = "ProRes RAW"
    case proResRAWHQ = "ProRes RAW HQ"
    var id: String { rawValue }

    var type: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        // Four-character codes, so it builds on SDKs that don't name them.
        case .proResRAW: return AVVideoCodecType(rawValue: "aprn")
        case .proResRAWHQ: return AVVideoCodecType(rawValue: "aprh")
        }
    }

    var isRAW: Bool { self == .proResRAW || self == .proResRAWHQ }
    var isProRes: Bool { rawValue.hasPrefix("ProRes") }
    /// H.264 has no HDR or Log on the iPhone.
    func allows(_ look: Look) -> Bool { self == .h264 ? look == .sdr : true }
}

/// 16:9 sizes. (The 48 MP sensors also have 4:3 "open gate" formats; those show in the formats list.)
enum Resolution: String, CaseIterable, Identifiable {
    case uhd = "4K"
    case fhd = "1080p"
    case hd = "720p"
    var id: String { rawValue }
    var width: Int32 { self == .uhd ? 3840 : self == .fhd ? 1920 : 1280 }
    var height: Int32 { self == .uhd ? 2160 : self == .fhd ? 1080 : 720 }
}

let frameRates: [Int] = [24, 25, 30, 48, 50, 60, 100, 120, 240]

/// The camera's lenses. 2x and 8x are crops of the 48 MP sensors (Apple calls them optical quality).
enum Lens: String, CaseIterable, Identifiable {
    case ultraWide = "0.5"
    case main = "1"
    case main2x = "2"
    case tele = "4"
    case tele8x = "8"
    var id: String { rawValue }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .main, .main2x: return .builtInWideAngleCamera
        case .tele, .tele8x: return .builtInTelephotoCamera
        }
    }
    var crop: CGFloat { self == .main2x || self == .tele8x ? 2 : 1 }
    var label: String { rawValue + "x" }
}

// MARK: - format facts

let tenBitSubtypes: Set<FourCharCode> = [
    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
]
let eightBitSubtypes: Set<FourCharCode> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
]

extension AVCaptureDevice.Format {
    var subtype: FourCharCode { CMFormatDescriptionGetMediaSubType(formatDescription) }
    var size: CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(formatDescription) }
    var isTenBit: Bool { tenBitSubtypes.contains(subtype) }
    /// Not a normal YUV picture: the RAW (Bayer) formats that ProRes RAW records from.
    var isRawLike: Bool { !tenBitSubtypes.contains(subtype) && !eightBitSubtypes.contains(subtype) }
    /// A sensor (Bayer) format, the kind ProRes RAW records from: "btp2" (96VersatileBayerPacked12) and
    /// the plain Bayer types ("rgg4", "grb4", "gbr4", "bgg4"). Not the compressed YUV ones ("&8v0", "&xv0"…),
    /// which isRawLike also counts.
    var isBayer: Bool {
        let c = fourCC(subtype)
        return c.hasPrefix("bt") || ["rgg4", "grb4", "gbr4", "bgg4"].contains(c)
    }
    var maxFps: Double { videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
    func supports(fps: Int) -> Bool {
        videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) + 0.01 && Double(fps) <= $0.maxFrameRate + 0.01 }
    }
    var colorSpaceRaws: [Int] { supportedColorSpaces.map { $0.rawValue } }

    /// One line for the formats list: "3840x2160 · 10-bit · 1-120 fps · HLG, Log 2".
    var summary: String {
        let names = colorSpaceRaws.map { raw -> String in
            switch raw { case 0: return "sRGB"; case 1: return "P3"; case 2: return "HLG"; case 3: return "Log"; case 4: return "Log 2"; default: return "cs\(raw)" }
        }
        let bits = isRawLike ? "RAW " + fourCC(subtype) : isTenBit ? "10-bit" : "8-bit"
        let fps = videoSupportedFrameRateRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" }.joined(separator: ",")
        return "\(size.width)x\(size.height) · \(bits) · \(fps) fps · " + names.joined(separator: ", ")
    }
}

func fourCC(_ c: FourCharCode) -> String {
    let b = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "\(c)"
}

/// The camera format for this choice, or nil if the camera can't do it.
/// ProRes RAW needs a RAW format; the others need the colour space (and 10-bit for HDR and Log).
func pickFormat(_ device: AVCaptureDevice, res: Resolution, fps: Int, look: Look, codec: Codec) -> AVCaptureDevice.Format? {
    let fits = device.formats.filter { f in
        f.size.width == res.width && f.size.height == res.height && f.supports(fps: fps)
    }
    if codec.isRAW {
        // The sensor formats don't always have the exact video size (the RAW frame is the sensor's
        // own crop): the exact size first, else the nearest at this frame rate, larger before smaller.
        let raw = device.formats.filter { $0.isBayer && $0.supports(fps: fps) }
        if let exact = raw.first(where: { $0.size.width == res.width && $0.size.height == res.height }) { return exact }
        return raw.sorted { a, b in
            let da = abs(Int(a.size.width) - Int(res.width)), db = abs(Int(b.size.width) - Int(res.width))
            if da != db { return da < db }
            return a.size.width > b.size.width
        }.first
    }
    let ok = fits.filter { f in
        !f.isRawLike && f.colorSpaceRaws.contains(look.colorSpaceRaw) && (!look.tenBit || f.isTenBit)
    }
    // Prefer video range, not binned (higher max ISO = binned on some sensors: take the lowest), stabilization capable.
    return ok.sorted { a, b in
        if a.isVideoStabilizationModeSupported(.cinematic) != b.isVideoStabilizationModeSupported(.cinematic) {
            return a.isVideoStabilizationModeSupported(.cinematic)
        }
        return a.maxFps < b.maxFps
    }.first
}

// MARK: - exposure steps

let shutterDenominators: [Int32] = [24, 25, 30, 40, 48, 50, 60, 80, 100, 120, 125, 160, 200, 240, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 6400, 8000]
let isoSteps: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600]

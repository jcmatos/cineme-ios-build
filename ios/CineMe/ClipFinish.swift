import AVFoundation
import CoreMedia

// After a clip is recorded: add a time-of-day timecode track and/or tag the anamorphic pixel
// aspect ratio. No re-encoding: only the movie header (the file's index) is rewritten, plus a
// 4-byte timecode sample. The original is never touched until the new one checks out:
//  1. The clip is cloned (APFS: instant, no extra space) into a hidden folder beside it.
//  2. The clone is edited in place (AVMutableMovie, writeHeader .addMovieHeaderToDestination:
//     "removes any existing movie header ... preserving any other data in the file").
//  3. The clone is checked (plays, same length, same metadata, timecode there, self-contained).
//  4. Only then it replaces the original. Anything wrong: the original stays as recorded.
// Drives that can't clone (most USB-C drives are exFAT) are skipped: a full copy of a big ProRes
// file would be slow and need the space twice.
//
// Timecode track as Apple's TN2310 describes it: a 'tmcd' track with one sample (the frame
// number of the first frame, big-endian Int32) for the whole clip, linked to the video track.

enum ClipFinish {
    struct Plan {
        /// Wall-clock time of the clip's first frame; nil = no timecode.
        var start: Date?
        var tcRate = 30
        /// Pixel aspect ratio to tag; nil = none.
        var pixelAspect: (h: Int, v: Int)?
        var isEmpty: Bool { start == nil && pixelAspect == nil }
    }

    /// What to do for this clip, from the settings. [start]: when its first frame was taken.
    static func plan(start: Date?, fps: Int) -> Plan {
        let d = UserDefaults.standard
        let tc = d.object(forKey: ProAV.kTimecode) as? Bool ?? false
        let sq = Squeeze(rawValue: d.string(forKey: ProAV.kSqueeze) ?? "") ?? .off
        let tag = d.object(forKey: ProAV.kTagSqueeze) as? Bool ?? true
        return Plan(start: tc ? (start ?? Date()) : nil, tcRate: TimeOfDay.rate(fps), pixelAspect: tag ? sq.pixelAspect : nil)
    }

    enum Failure: Error { case step(String) }

    /// Runs the plan on [url], then [done] on the main thread with a note for the log (nil = nothing to say).
    static func run(_ url: URL, _ plan: Plan, done: @escaping (String?) -> Void) {
        guard !plan.isEmpty else { DispatchQueue.main.async { done(nil) }; return }
        Task.detached(priority: .userInitiated) {
            let note: String
            do {
                note = try await ClipFinish.finish(url, plan)
            } catch Failure.step(let s) {
                note = "clip kept as recorded (\(s))"
            } catch {
                note = "clip kept as recorded (\(error.localizedDescription))"
            }
            DispatchQueue.main.async { done(note) }
        }
    }

    private static func finish(_ url: URL, _ plan: Plan) async throws -> String {
        let fm = FileManager.default
        let clones = (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
        guard clones else { throw Failure.step("this drive can't clone files: no timecode / tag") }

        // 1. Clone (same volume, hidden folder: the video manager and backup skip hidden files).
        let dir = url.deletingLastPathComponent().appendingPathComponent(".cineme-work", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let work = dir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: work)
        try fm.copyItem(at: url, to: work)
        defer { try? fm.removeItem(at: work) }   // gone already when it replaced the original

        let original = AVURLAsset(url: url)
        let origDuration = try await original.load(.duration)
        let origMetadata = try await original.load(.metadata).count

        // 2. Edit the clone's header.
        guard let movie = AVMovie(url: work, options: nil).mutableCopy() as? AVMutableMovie else { throw Failure.step("movie") }
        let videos = movie.tracks(withMediaType: .video)
        guard let video = videos.first else { throw Failure.step("no video track") }
        var did: [String] = []

        if let par = plan.pixelAspect {
            var n = 0
            for t in videos { n += tag(t, h: par.h, v: par.v) }
            guard n > 0 else { throw Failure.step("pixel aspect") }
            did.append("tagged \(par.h):\(par.v)")
        }

        var tmp: URL? = nil
        defer { if let t = tmp { try? fm.removeItem(at: t) } }
        if let start = plan.start {
            let range = video.timeRange
            let rate = plan.tcRate
            // The timecode of the video's first frame.
            let first = TimeOfDay.frames(at: start.addingTimeInterval(CMTimeGetSeconds(range.start)), rate: rate)
            let t = try await timecodeMovie(frame: Int32(first), rate: Int32(rate), duration: range.duration)
            tmp = t
            let src = AVURLAsset(url: t)
            guard let srcTrack = try await src.loadTracks(withMediaType: .timecode).first else { throw Failure.step("timecode source") }
            let srcRange = try await srcTrack.load(.timeRange)
            for old in movie.tracks(withMediaType: .timecode) { movie.removeTrack(old) }
            guard let tc = movie.addMutableTrack(withMediaType: .timecode, copySettingsFrom: srcTrack, options: nil) else {
                throw Failure.step("timecode track")
            }
            // The 4-byte sample goes into the clip itself (self-contained, no reference to tmp).
            tc.mediaDataStorage = AVMediaDataStorage(url: work, options: nil)
            try tc.insertTimeRange(srcRange, of: srcTrack, at: range.start, copySampleData: true)
            for v in videos { v.addTrackAssociation(to: tc, type: .timecode) }
            did.append("timecode \(TimeOfDay.text(frames: first, rate: rate)) @\(rate)")
        }

        try movie.writeHeader(to: work, fileType: .mov, options: .addMovieHeaderToDestination)

        // 3. Check the clone.
        let check = AVURLAsset(url: work)
        let vids = try await check.loadTracks(withMediaType: .video)
        let dur = try await check.load(.duration)
        let meta = try await check.load(.metadata).count
        guard !vids.isEmpty, abs(CMTimeGetSeconds(dur) - CMTimeGetSeconds(origDuration)) < 0.25 else { throw Failure.step("check: length") }
        guard meta >= origMetadata else { throw Failure.step("check: metadata") }
        if plan.start != nil {
            guard try await !check.loadTracks(withMediaType: .timecode).isEmpty else { throw Failure.step("check: timecode") }
        }
        guard AVMovie(url: work, options: nil).tracks.allSatisfy({ $0.isSelfContained }) else { throw Failure.step("check: not self-contained") }

        // 4. Swap it in (atomic rename on the same volume).
        _ = try fm.replaceItemAt(url, withItemAt: work)
        return did.joined(separator: ", ")
    }

    /// Writes the pixel aspect ratio into a video track's format descriptions. Returns how many.
    private static func tag(_ t: AVMutableMovieTrack, h: Int, v: Int) -> Int {
        var n = 0
        for any in t.formatDescriptions {
            let old = any as! CMFormatDescription
            guard CMFormatDescriptionGetMediaType(old) == kCMMediaType_Video else { continue }
            var ext = (CMFormatDescriptionGetExtensions(old) as NSDictionary?) as? [String: Any] ?? [:]
            // Apple: remove these from a copy, or the change may be ignored.
            ext.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription as String)
            ext.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry as String)
            ext[kCMFormatDescriptionExtension_PixelAspectRatio as String] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: h,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: v,
            ]
            let dims = CMVideoFormatDescriptionGetDimensions(old)
            var new: CMFormatDescription?
            guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: CMFormatDescriptionGetMediaSubType(old),
                                                 width: dims.width, height: dims.height, extensions: ext as CFDictionary,
                                                 formatDescriptionOut: &new) == noErr, let new = new else { continue }
            t.replaceFormatDescription(old, with: new)
            n += 1
        }
        return n
    }

    /// A tiny temporary movie holding only the timecode track (AVAssetWriter, as in TN2310).
    private static func timecodeMovie(frame: Int32, rate: Int32, duration: CMTime) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString).mov")
        // 'tmcd' (kCMTimeCodeFormatType_TimeCode32); flag 2 = kCMTimeCodeFlag_24HourMax.
        var fd: CMTimeCodeFormatDescription?
        guard CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault, timeCodeFormatType: 0x746D_6364,
                                                frameDuration: CMTime(value: 1, timescale: rate), frameQuanta: UInt32(rate),
                                                flags: 2, extensions: nil, formatDescriptionOut: &fd) == noErr,
              let format = fd else { throw Failure.step("timecode format") }

        var number = frame.bigEndian
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let data = block,
              CMBlockBufferReplaceDataBytes(with: &number, blockBuffer: data, offsetIntoDestination: 0, dataLength: 4) == kCMBlockBufferNoErr
        else { throw Failure.step("timecode data") }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 4
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: data, dataReady: true, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                   sampleBufferOut: &sb) == noErr, let sample = sb else { throw Failure.step("timecode sample") }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: format)
        guard writer.canAdd(input) else { throw Failure.step("timecode writer") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.step("timecode writer start") }
        writer.startSession(atSourceTime: .zero)
        var waits = 0
        while !input.isReadyForMoreMediaData && waits < 100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waits += 1
        }
        guard input.append(sample) else { throw writer.error ?? Failure.step("timecode append") }
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.step("timecode writer finish") }
        return url
    }
}

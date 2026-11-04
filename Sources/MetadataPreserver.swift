import Foundation
import ImageIO
import AVFoundation
import ImageCaptureCore

/// Carries the device's dates over to the copied files.
/// The file bytes themselves (EXIF, GPS, QuickTime metadata, HEIC/HEVC data) are copied untouched;
/// this restores the *filesystem* Created / Modified dates that Image Capture throws away.
enum MetadataPreserver {
    struct Dates {
        var created: Date
        var modified: Date
    }

    /// Capture time read from the file itself.
    struct CaptureTime {
        /// Wall-clock time where the photo was taken, stored as a "floating" Date
        /// (interpret and format it in UTC). Used for date folders and renamed files.
        var wallClock: Date?
        /// The real instant of capture, when the file records its time-zone offset.
        var absolute: Date?
    }

    /// Converts an absolute instant to a floating wall-clock Date in this Mac's time zone.
    static func wallClockInCurrentZone(_ date: Date) -> Date {
        date.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: date)))
    }

    // MARK: Reading capture time

    static func captureTime(of url: URL, isVideo: Bool) async -> CaptureTime? {
        isVideo ? await videoCaptureTime(url) : imageCaptureTime(url)
    }

    /// EXIF DateTimeOriginal is local wall-clock time; OffsetTimeOriginal (iPhone, most modern cameras)
    /// gives the zone it was in.
    private static func imageCaptureTime(_ url: URL) -> CaptureTime? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let wall = floatingFormatter("yyyy:MM:dd HH:mm:ss").date(from: stamp)
        else { return nil }
        let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(parseOffset)
        return CaptureTime(wallClock: wall, absolute: offset.map { wall.addingTimeInterval(-$0) })
    }

    /// iPhone movies store "com.apple.quicktime.creationdate" as e.g. 2026-11-03T14:30:12-0500,
    /// which keeps the local time and its offset.
    private static func videoCaptureTime(_ url: URL) async -> CaptureTime? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        let absolute = try? await item.load(.dateValue)
        if let text = try? await item.load(.stringValue), text.count >= 19 {
            let head = String(text.prefix(19)).replacingOccurrences(of: " ", with: "T")
            if let wall = floatingFormatter("yyyy-MM-dd'T'HH:mm:ss").date(from: head) {
                let offset = parseOffset(String(text.dropFirst(19)))
                return CaptureTime(wallClock: wall,
                                   absolute: offset.map { wall.addingTimeInterval(-$0) } ?? absolute)
            }
        }
        guard let absolute else { return nil }
        // No local time recorded: fall back to this Mac's zone.
        return CaptureTime(wallClock: wallClockInCurrentZone(absolute), absolute: absolute)
    }

    /// "+02:00", "-0500", "Z" → seconds east of UTC.
    private static func parseOffset(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "Z" { return 0 }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let digits = s.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) else { return nil }
        let seconds = TimeInterval(hh * 3600 + mm * 60)
        return sign == "-" ? -seconds : seconds
    }

    private static func floatingFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// The Live Photo content identifier stored in an iPhone still (Apple MakerNote tag 17).
    /// Present only on the still half of a Live Photo.
    static func livePhotoID(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        if let id = maker["17"] as? String, !id.isEmpty { return id }
        return nil
    }

    // MARK: Finder dates

    /// Created = the real capture instant (from the file when it records its zone, otherwise the device),
    /// Modified = the device's file modification date.
    static func dates(for file: ICCameraFile, capture: CaptureTime?) -> Dates? {
        let created = capture?.absolute ?? file.exifCreationDate ?? file.fileCreationDate ?? file.creationDate
        let modified = file.fileModificationDate ?? file.exifModificationDate ?? file.modificationDate
        guard let c = created ?? modified ?? capture?.wallClock else { return nil }
        let m = modified ?? c
        // macOS pulls the creation date back if modified < created, so keep them ordered.
        return Dates(created: min(c, m), modified: max(c, m))
    }

    static func apply(_ dates: Dates, to url: URL) throws {
        let fm = FileManager.default
        // Modified first, then Created (setting Created later than Modified is otherwise undone).
        try fm.setAttributes([.modificationDate: dates.modified], ofItemAtPath: url.path)
        try fm.setAttributes([.creationDate: dates.created], ofItemAtPath: url.path)
    }
}

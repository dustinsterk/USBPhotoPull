import AppKit
import ImageCaptureCore
import UniformTypeIdentifiers

/// What a file is, for the type filter.
enum MediaKind {
    case photo        // camera photo (IMG_1234.HEIC / .JPG / .DNG …)
    case video
    case screenshot   // iPhone screenshots are PNGs
    case otherImage   // saved or downloaded images with non-camera names, GIFs, etc.
}

enum ImportState: Equatable {
    case new
    case alreadyImported
    case queued
    case importing
    case imported
    case failed(String)
}

/// One photo/video on the connected device.
final class PhotoItem: ObservableObject, Identifiable {
    let id: ObjectIdentifier
    let file: ICCameraFile
    let name: String
    let size: Int64
    let captureDate: Date?
    let isVideo: Bool
    let kind: MediaKind
    let duration: Double
    /// Lower-cased name without extension, used to pair Live Photo stills with their movies.
    let baseKey: String
    /// Capture day, for grouping ("yyyy-MM-dd", or "unknown").
    let dayKey: String
    let dayStart: Date?
    var isLivePhotoVideo = false
    /// Apple's Live Photo content identifier, read from the imported still. Non-nil means this
    /// photo has a Live Photo video on the phone, even if the phone isn't offering it yet.
    var livePhotoID: String?
    /// Local wall-clock capture time read from the file during import (floating, see MetadataPreserver).
    var localStamp: Date?

    /// Wall-clock capture time used for date folders and renamed files: the time where the photo was
    /// taken once known, otherwise the device's date shown in this Mac's time zone.
    var stamp: Date? {
        localStamp ?? captureDate.map(MetadataPreserver.wallClockInCurrentZone)
    }

    @Published var thumbnail: NSImage?
    @Published var state: ImportState = .new
    /// When the thumbnail was last asked for (a request the phone drops can be retried).
    var thumbnailRequestedAt: Date?

    init(file: ICCameraFile) {
        self.file = file
        self.id = ObjectIdentifier(file)
        self.name = file.name ?? "Untitled"
        self.size = Int64(file.fileSize)
        self.captureDate = file.exifCreationDate ?? file.creationDate ?? file.fileCreationDate
        self.duration = file.duration

        let ext = (name as NSString).pathExtension
        self.baseKey = (name as NSString).deletingPathExtension.lowercased()
        if let date = captureDate {
            let start = Calendar.current.startOfDay(for: date)
            self.dayStart = start
            self.dayKey = PhotoItem.dayKeyFormatter.string(from: start)
        } else {
            self.dayStart = nil
            self.dayKey = "unknown"
        }
        let type = file.uti.flatMap { UTType($0) } ?? UTType(filenameExtension: ext)
        self.isVideo = type?.conforms(to: .movie) ?? false
        if isVideo {
            kind = .video
        } else if ext.lowercased() == "png" {
            kind = .screenshot
        } else if PhotoItem.hasCameraName(name) && ext.lowercased() != "gif" {
            kind = .photo
        } else {
            kind = .otherImage
        }
        thumbnail = ThumbnailCache.cached(matchKey)
    }

    /// IMG_1234 / IMG_E1234 (iPhone) and common camera prefixes.
    private static let cameraName = try? NSRegularExpression(
        pattern: "^(IMG_E?\\d{4}|DSC[_F]?\\d{4}|_DSC\\d{4}|DJI_\\d{4}|GOPR\\d{4}|P\\d{7})",
        options: [.caseInsensitive])

    static func hasCameraName(_ name: String) -> Bool {
        guard let re = cameraName else { return true }
        return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Identifies the same file across reconnects. File names alone are NOT unique on an iPhone
    /// (IMG_0241.HEIC can exist from 2019 and from today), so size and capture time are included.
    var matchKey: String {
        "\(name.lowercased())|\(size)|\(Int((captureDate?.timeIntervalSince1970 ?? 0).rounded()))"
    }

    /// True when a verified copy exists in the destination.
    var isDone: Bool { state == .imported || state == .alreadyImported }

    var failureMessage: String? {
        if case .failed(let msg) = state { return msg }
        return nil
    }
}

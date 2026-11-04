import AppKit
import ImageCaptureCore

/// Where files go in the destination and what they're called.
extension DeviceManager {
    static let yearFormatter = posixFormatter("yyyy")
    static let dayFormatter = posixFormatter("yyyy-MM-dd")
    static let stampFormatter = posixFormatter("yyyy-MM-dd_HHmmss")

    /// Stamps are floating wall-clock Dates (see MetadataPreserver.CaptureTime), so format them in UTC.
    static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// Destination root for an item (screenshots can have their own folder).
    func root(for item: PhotoItem, base: URL) -> URL {
        screenshotsFolder && item.kind == .screenshot
            ? base.appendingPathComponent("Screenshots", isDirectory: true)
            : base
    }

    static func folder(base: URL, date: Date?, subfolders: Bool) -> URL {
        guard subfolders else { return base }
        guard let date else { return base.appendingPathComponent("Unknown Date", isDirectory: true) }
        return base
            .appendingPathComponent(yearFormatter.string(from: date), isDirectory: true)
            .appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
    }

    /// The file name an item gets in the destination under the chosen rename mode.
    static func destinationName(for name: String, date: Date?, mode: RenameMode) -> String {
        guard let date, mode != .original else { return name }
        let stamp = stampFormatter.string(from: date)
        switch mode {
        case .original:
            return name
        case .dateTimeOriginal:
            return "\(stamp)_\(name)"
        case .dateTime:
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? stamp : "\(stamp).\(ext)"
        }
    }

    static func sizeOfFile(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    /// Finds an existing copy (same name, or a "-N" renamed variant) with the same byte size.
    static func existingCopy(in folder: URL, name: String, size: Int64) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 0...50 {
            let candidate = n == 0 ? name : (ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            let url = folder.appendingPathComponent(candidate)
            guard let existing = sizeOfFile(url) else { return nil } // first gap ends the chain
            if size <= 0 || existing == size { return url }
        }
        return nil
    }

    /// A filename that doesn't exist in the folder yet ("IMG_0001.HEIC" → "IMG_0001-1.HEIC").
    static func uniqueName(in folder: URL, name: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }
}

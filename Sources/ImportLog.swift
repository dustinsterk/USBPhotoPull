import Foundation

/// Appends one CSV row per file to "USBPhotoPull Import Log.csv" in the destination folder.
/// Rows are written as each file finishes, so the log survives a crash or unplug mid-import.
final class ImportLog {
    static let fileName = "USBPhotoPull Import Log.csv"
    static let columns = ["Time", "Device", "Device File", "Saved As", "Bytes",
                          "Capture Time (local)", "Created Set", "Modified Set", "Result", "Details"]

    struct Row {
        var device: String
        var deviceFile: String
        var savedAs: String = ""
        var bytes: Int64? = nil
        /// Floating local capture time (see MetadataPreserver.CaptureTime).
        var captureDate: Date? = nil
        var dates: MetadataPreserver.Dates? = nil
        var result: String
        var details: String = ""
    }

    let url: URL
    private var handle: FileHandle?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Capture times are floating local wall-clock stamps, so they're formatted in UTC.
    private static let captureFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func url(in destination: URL) -> URL {
        destination.appendingPathComponent(fileName)
    }

    init?(destination: URL) {
        url = Self.url(in: destination)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // UTF-8 BOM so Excel and Numbers read accented file/device names correctly.
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Self.line(Self.columns).data(using: .utf8) ?? Data())
            guard fm.createFile(atPath: url.path, contents: data) else { return nil }
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        handle = h
    }

    deinit { close() }

    func append(_ row: Row) {
        func date(_ d: Date?) -> String { d.map { Self.timeFormatter.string(from: $0) } ?? "" }
        let fields = [
            date(Date()),
            row.device,
            row.deviceFile,
            row.savedAs,
            row.bytes.map(String.init) ?? "",
            row.captureDate.map { Self.captureFormatter.string(from: $0) } ?? "",
            date(row.dates?.created),
            date(row.dates?.modified),
            row.result,
            row.details,
        ]
        guard let data = Self.line(fields).data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// Path relative to the destination, for a readable "Saved As" column.
    static func relativePath(_ url: URL, to base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") { return String(path.dropFirst(basePath.count + 1)) }
        return path
    }

    private static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    private static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}

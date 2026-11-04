import AppKit
import ImageCaptureCore

/// Spacebar preview downloads and small UI helpers.
extension DeviceManager {
    static let previewVideoLimit: Int64 = 300_000_000
    static let previewFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("USBPhotoPull-Preview", isDirectory: true)

    func item(with id: ObjectIdentifier) -> PhotoItem? {
        items.first { $0.id == id }
    }

    /// Downloads a full-size copy to a temporary cache for the spacebar preview (last 30 kept).
    @MainActor
    func previewFile(for item: PhotoItem) async throws -> URL {
        let fm = FileManager.default
        if let url = previewCache[item.id], fm.fileExists(atPath: url.path) { return url }
        try fm.createDirectory(at: Self.previewFolder, withIntermediateDirectories: true)
        let ext = (item.name as NSString).pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let target = Self.previewFolder.appendingPathComponent(name)
        let saved = try await download(item.file, to: Self.previewFolder, as: name,
                                       expectedSize: item.size, watching: target)
        let url = resolveSavedURL(saved, folder: Self.previewFolder, fallbackName: name)
        previewCache[item.id] = url
        previewOrder.append(item.id)
        while previewOrder.count > 30 {
            let old = previewOrder.removeFirst()
            if let u = previewCache.removeValue(forKey: old) { try? fm.removeItem(at: u) }
        }
        return url
    }

    func clearPreviewCache() {
        try? FileManager.default.removeItem(at: Self.previewFolder)
        previewCache = [:]
        previewOrder = []
    }

    @MainActor
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }
}

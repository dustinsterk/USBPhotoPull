import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps thumbnails so they don't have to be fetched from the phone again — in memory for this
/// session and on disk (~/Library/Caches/USBPhotoPull/Thumbnails) across reconnects and launches.
/// Keyed by PhotoItem.matchKey (name + size + capture time), which is stable across sessions.
enum ThumbnailCache {
    private static let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 6000
        return c
    }()

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("USBPhotoPull/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let io = DispatchQueue(label: "USBPhotoPull.thumbnails", qos: .utility)

    private static func fileURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".jpg")
    }

    /// Instant memory lookup (used when building the library).
    static func cached(_ key: String) -> NSImage? {
        memory.object(forKey: key as NSString)
    }

    /// Memory, then disk. Calls back on the main thread with nil if it isn't cached.
    static func load(_ key: String, completion: @escaping (NSImage?) -> Void) {
        if let img = memory.object(forKey: key as NSString) {
            completion(img)
            return
        }
        let url = fileURL(key)
        io.async {
            let img = NSImage(contentsOf: url)
            if let img { memory.setObject(img, forKey: key as NSString) }
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Stores a thumbnail received from the device.
    static func store(_ cg: CGImage, key: String) -> NSImage {
        let img = NSImage(cgImage: cg, size: .zero)
        memory.setObject(img, forKey: key as NSString)
        let url = fileURL(key)
        io.async {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return img
    }

    /// Size of the on-disk cache in bytes.
    static func diskSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clear() {
        memory.removeAllObjects()
        io.async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

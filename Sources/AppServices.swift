import AppKit
import UserNotifications

/// "Import finished" notifications. Shown only when USBPhotoPull isn't the frontmost app.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func importFinished(title: String, body: String) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest) // bounce the Dock icon once
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Draws a progress bar over the app's Dock icon during an import.
final class DockProgress {
    static let shared = DockProgress()

    private var view: NSView?
    private var indicator: NSProgressIndicator?

    private func makeView() -> (NSView, NSProgressIndicator) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        let icon = NSImageView(frame: view.bounds)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        let bar = NSProgressIndicator(frame: NSRect(x: 14, y: 8, width: 100, height: 20))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .regular
        view.addSubview(bar)
        return (view, bar)
    }

    func update(_ fraction: Double) {
        if view == nil {
            let (v, bar) = makeView()
            view = v
            indicator = bar
        }
        let tile = NSApp.dockTile
        if tile.contentView !== view { tile.contentView = view }
        indicator?.doubleValue = min(max(fraction, 0), 1)
        tile.display()
    }

    func clear() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        view = nil
        indicator = nil
    }
}

/// A small text log of device events (~/Library/Logs/USBPhotoPull/device.log) for diagnosing
/// connection problems. Help ▸ Open Device Log.
enum DeviceLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/USBPhotoPull", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("device.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        // Keep it small: start over past 1 MB.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: data)
            return
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        }
    }

    static func open() {
        if !FileManager.default.fileExists(atPath: url.path) { write("Log created") }
        NSWorkspace.shared.open(url)
    }
}

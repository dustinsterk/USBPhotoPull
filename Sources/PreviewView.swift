import SwiftUI
import AVKit
import ImageIO

/// Spacebar preview: full-size photo or playable video, ← → to step through the grid.
struct PreviewView: View {
    @ObservedObject var manager: DeviceManager
    @Binding var currentID: ObjectIdentifier?
    let close: () -> Void

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var message: String?

    private var item: PhotoItem? {
        guard let id = currentID else { return nil }
        if let i = manager.visibleIndex[id], i < manager.visibleItems.count { return manager.visibleItems[i] }
        return manager.item(with: id)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") // stamps are floating local times
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    PlayerView(player: player)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if let thumb = item?.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFit().opacity(0.6)
                }
                if loading {
                    ProgressView().controlSize(.large)
                }
                if let message {
                    Text(message)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Previous (←)")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next (→)")
                if let item {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.headline).lineLimit(1)
                        Text(details(for: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("Selected", isOn: Binding(
                        get: { manager.selection.contains(item.id) },
                        set: { on in
                            if on { manager.selection.insert(item.id) } else { manager.selection.remove(item.id) }
                        }))
                        .toggleStyle(.checkbox)
                    if let i = manager.visibleIndex[item.id] {
                        Text("\(i + 1) of \(manager.visibleItems.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Spacer()
                }
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                // Space closes too, like Quick Look.
                Button("", action: close)
                    .keyboardShortcut(.space, modifiers: [])
                    .frame(width: 0, height: 0).opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 860, idealWidth: 1100, minHeight: 620, idealHeight: 800)
        .task(id: currentID) { await load() }
        .onDisappear { player?.pause() }
    }

    private func details(for item: PhotoItem) -> String {
        var parts: [String] = []
        if let stamp = item.stamp { parts.append(Self.dateFormatter.string(from: stamp)) }
        parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        if item.isVideo {
            let t = Int(item.duration.rounded())
            parts.append(String(format: "%d:%02d", t / 60, t % 60))
        }
        if item.isDone { parts.append("Imported") }
        return parts.joined(separator: " · ")
    }

    private func step(_ delta: Int) {
        let list = manager.visibleItems
        guard !list.isEmpty else { return }
        let i = currentID.flatMap { manager.visibleIndex[$0] } ?? 0
        let j = min(max(i + delta, 0), list.count - 1)
        currentID = list[j].id
    }

    @MainActor
    private func load() async {
        player?.pause()
        player = nil
        image = nil
        message = nil
        guard let item else { return }
        manager.requestThumbnail(for: item)

        if item.isVideo && item.size > DeviceManager.previewVideoLimit {
            let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            message = "This video is \(size). Import it to watch it."
            return
        }

        loading = true
        do {
            let url = try await manager.previewFile(for: item)
            guard currentID == item.id else { return }
            if item.isVideo {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            } else {
                image = Self.orientedImage(at: url)
                if image == nil { message = "This file type can’t be previewed." }
            }
        } catch {
            if currentID == item.id { message = "Couldn’t load preview: \(error.localizedDescription)" }
        }
        if currentID == item.id { loading = false }
    }

    /// Decodes with the EXIF orientation applied, capped at 2400 px for speed.
    private static func orientedImage(at url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// AppKit's AVPlayerView wrapped for SwiftUI (used instead of SwiftUI's VideoPlayer,
/// which crashed in this app).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

import SwiftUI
import ImageCaptureCore

/// One item to delete from the device, with every file that belongs to it
/// (the photo or video itself, plus its Live Photo video and .AAE edits).
struct DeleteEntry: Identifiable {
    let item: PhotoItem
    let files: [ICCameraItem]
    var id: ObjectIdentifier { item.id }

    /// Extra files beyond the item itself.
    var extraVideos: Int {
        files.dropFirst().filter { DeviceManager.movieExtensions.contains((($0.name ?? "") as NSString).pathExtension.lowercased()) }.count
    }
    var extraEdits: Int { max(files.count - 1 - extraVideos, 0) }
    var bytes: Int64 {
        files.reduce(0) { $0 + Int64(($1 as? ICCameraFile)?.fileSize ?? 0) }
    }
}

/// Everything waiting for confirmation after an import.
struct DeleteReview: Identifiable {
    let id = UUID()
    let entries: [DeleteEntry]
    let kept: [(String, String)]
    let destination: URL
    let device: String
    let camera: ICCameraDevice

    struct Day: Identifiable {
        let id: String
        let day: Date?
        let entries: [DeleteEntry]
    }

    /// Entries grouped by capture day, newest first.
    var days: [Day] {
        let grouped = Dictionary(grouping: entries, by: \.item.dayKey)
        return grouped.map { key, list in
            Day(id: key, day: list.first?.item.dayStart,
                entries: list.sorted { ($0.item.captureDate ?? .distantPast) > ($1.item.captureDate ?? .distantPast) })
        }
        .sorted { ($0.day ?? .distantPast) > ($1.day ?? .distantPast) }
    }
}

/// The sheet shown before anything is deleted from the device.
struct DeleteReviewView: View {
    @ObservedObject var manager: DeviceManager
    let review: DeleteReview

    @State private var excluded = Set<ObjectIdentifier>()
    @State private var expanded = Set<String>()
    @State private var showKept = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy"
        return f
    }()
    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") // stamps are floating local capture times
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var chosen: [DeleteEntry] { review.entries.filter { !excluded.contains($0.id) } }

    var body: some View {
        let days = review.days
        let picked = chosen
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Delete \(picked.count) item\(picked.count == 1 ? "" : "s") from \(review.device)?")
                    .font(.title2.bold())
                Text("Each one is verified in \(review.destination.lastPathComponent). Deleting over USB is permanent — it doesn’t go to Recently Deleted.")
                    .foregroundStyle(.secondary)
            }

            summary(picked)

            if !review.kept.isEmpty {
                DisclosureGroup(isExpanded: $showKept) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(review.kept.enumerated()), id: \.offset) { _, row in
                            Text("\(row.0) — \(row.1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Keeping \(review.kept.count) on the phone (not safe to delete yet)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            List {
                ForEach(days) { day in
                    dayRow(day)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 260)

            HStack {
                Button("Select All") { excluded = [] }
                Button("Select None") { excluded = Set(review.entries.map(\.id)) }
                Spacer()
                Button("Keep All on iPhone") { manager.keepAllFromReview() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete \(picked.count) from iPhone", role: .destructive) {
                    manager.confirmDeleteReview(excluding: excluded)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 600, idealHeight: 700)
    }

    // MARK: Summary

    private func summary(_ picked: [DeleteEntry]) -> some View {
        var counts: [String] = []
        let photos = picked.filter { $0.item.kind == .photo }.count
        let videos = picked.filter { $0.item.kind == .video }.count
        let shots = picked.filter { $0.item.kind == .screenshot }.count
        let other = picked.filter { $0.item.kind == .otherImage }.count
        if photos > 0 { counts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { counts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if shots > 0 { counts.append("\(shots) screenshot\(shots == 1 ? "" : "s")") }
        if other > 0 { counts.append("\(other) other image\(other == 1 ? "" : "s")") }

        let liveVideos = picked.reduce(0) { $0 + $1.extraVideos }
        let edits = picked.reduce(0) { $0 + $1.extraEdits }
        var extras: [String] = []
        if liveVideos > 0 { extras.append("\(liveVideos) Live Photo video\(liveVideos == 1 ? "" : "s")") }
        if edits > 0 { extras.append("\(edits) edit file\(edits == 1 ? "" : "s")") }

        let stamps = picked.compactMap(\.item.stamp)
        var range = ""
        if let lo = stamps.min(), let hi = stamps.max() {
            let a = Self.rangeFormatter.string(from: lo), b = Self.rangeFormatter.string(from: hi)
            range = a == b ? a : "\(a) – \(b)"
        }
        let bytes = picked.reduce(Int64(0)) { $0 + $1.bytes }

        return VStack(alignment: .leading, spacing: 3) {
            Text(counts.isEmpty ? "Nothing selected" : counts.joined(separator: " · ")).font(.headline)
            if !extras.isEmpty {
                Text("+ " + extras.joined(separator: " and ") + " that belong to them")
                    .foregroundStyle(.secondary)
            }
            Text([range, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Days

    @ViewBuilder
    private func dayRow(_ day: DeleteReview.Day) -> some View {
        let ids = day.entries.map(\.id)
        let pickedCount = ids.filter { !excluded.contains($0) }.count
        let isOpen = expanded.contains(day.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { pickedCount == ids.count },
                    set: { on in
                        if on { excluded.subtract(ids) } else { excluded.formUnion(ids) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Button {
                    if isOpen { expanded.remove(day.id) } else { expanded.insert(day.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption).frame(width: 10)
                        Text(day.day.map { Self.dayFormatter.string(from: $0) } ?? "Unknown date")
                            .font(.body.weight(.semibold))
                        Text(pickedCount == ids.count ? "\(ids.count) items" : "\(pickedCount) of \(ids.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if !isOpen {
                    HStack(spacing: 3) {
                        ForEach(day.entries.prefix(10)) { entry in
                            ReviewThumb(item: entry.item, size: 30, dimmed: excluded.contains(entry.id))
                                .onAppear { manager.requestThumbnail(for: entry.item) }
                        }
                        if day.entries.count > 10 {
                            Text("+\(day.entries.count - 10)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if isOpen {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 8)], spacing: 8) {
                    ForEach(day.entries) { entry in
                        VStack(spacing: 2) {
                            ReviewThumb(item: entry.item, size: 76, dimmed: excluded.contains(entry.id))
                                .overlay(alignment: .topLeading) {
                                    Image(systemName: excluded.contains(entry.id) ? "circle" : "checkmark.circle.fill")
                                        .foregroundStyle(excluded.contains(entry.id) ? Color.secondary : Color.red)
                                        .background(Circle().fill(Color.white))
                                        .padding(3)
                                }
                            Text(entry.item.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if excluded.contains(entry.id) { excluded.remove(entry.id) } else { excluded.insert(entry.id) }
                        }
                        .onAppear { manager.requestThumbnail(for: entry.item) }
                        .help(excluded.contains(entry.id) ? "Will be kept on the phone — click to delete it"
                                                          : "Will be deleted — click to keep it on the phone")
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Small thumbnail that updates when the item's thumbnail arrives.
private struct ReviewThumb: View {
    @ObservedObject var item: PhotoItem
    let size: CGFloat
    let dimmed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
            if let img = item.thumbnail {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: item.isVideo ? "video" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(dimmed ? 0.35 : 1)
    }
}

import SwiftUI
import AppKit
import ImageCaptureCore

struct ContentView: View {
    @EnvironmentObject var manager: DeviceManager
    @State private var confirmDelete = false
    @State private var pendingImport: [PhotoItem] = []
    /// Last plain- or ⌘-clicked item; ⇧-click selects the range from here, Space previews it.
    @State private var anchor: ObjectIdentifier?
    @State private var spaceAlert = false
    @State private var spaceMessage = ""
    @State private var showPreview = false
    @State private var previewID: ObjectIdentifier?

    var body: some View {
        NavigationSplitView {
            List(selection: $manager.selectedCamera) {
                Section("Devices") {
                    if manager.cameras.isEmpty {
                        Text("No devices connected")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.cameras, id: \.self) { cam in
                        Label(cam.name ?? "Device", systemImage: icon(for: cam))
                            .contextMenu {
                                Button("Reload Library") {
                                    if manager.selectedCamera === cam {
                                        manager.reloadDevice()
                                    } else {
                                        manager.selectedCamera = cam
                                    }
                                }
                                .disabled(manager.isImporting)
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { manager.reloadDevice() } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(manager.selectedCamera == nil || manager.isImporting)
                    .help("Reload the device library (⌘R)")
                }
            }
        }
        .confirmationDialog("Delete from device after importing?", isPresented: $confirmDelete) {
            Button("Import and Delete", role: .destructive) { run(pendingImport, delete: true) }
            Button("Import Only") { run(pendingImport, delete: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let lost = manager.liveVideosNotKept(in: pendingImport)
            Text("Each file is copied and its size verified first. Verified files — including ones already in the destination — are then removed from \(manager.selectedCamera?.name ?? "the device").")
            + Text(lost > 0 ? "\n\n\(lost) Live Photo video\(lost == 1 ? "" : "s") won’t be imported (Skip Live Photo videos is on) but will be deleted along with \(lost == 1 ? "its photo" : "their photos")." : "")
        }
        .alert("Not enough free space", isPresented: $spaceAlert) {
            Button("Import Anyway") { proceed(pendingImport) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(spaceMessage)
        }
        .sheet(item: $manager.deleteReview) { review in
            DeleteReviewView(manager: manager, review: review)
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showPreview, onDismiss: {
            if let previewID { anchor = previewID }
        }) {
            PreviewView(manager: manager, currentID: $previewID) { showPreview = false }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.selectedCamera?.name ?? "USBPhotoPull").font(.headline)
                    Text(manager.deviceStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(manager.deviceStatus)
                }
                Spacer()
                if !manager.items.isEmpty {
                    Text("\(manager.selection.count) selected · \(manager.newItems.count) new · \(manager.visibleItems.count) of \(manager.items.count) shown")
                        .font(.caption).foregroundStyle(.secondary)
                    selectMenu
                }
            }
            if !manager.items.isEmpty {
                filterBar
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $manager.mediaFilter) {
                ForEach(MediaFilter.allCases) { f in
                    Text("\(f.rawValue) (\(manager.kindCounts[f] ?? 0))").tag(f)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show only one kind of file. Screenshots = PNGs; Other images = saved/downloaded images with non-camera names and GIFs.")

            Toggle("Dates", isOn: $manager.dateFilterEnabled)
                .toggleStyle(.checkbox)
            DatePicker("From", selection: $manager.dateFrom, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .disabled(!manager.dateFilterEnabled)
                .fixedSize()
            Text("–").foregroundStyle(.secondary)
            DatePicker("To", selection: $manager.dateTo, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .disabled(!manager.dateFilterEnabled)
                .fixedSize()

            Toggle("Hide imported", isOn: $manager.hideImported)
                .toggleStyle(.checkbox)
            if manager.mediaFilter != .all || manager.dateFilterEnabled {
                Button("Clear Filters") {
                    manager.mediaFilter = .all
                    manager.dateFilterEnabled = false
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
            Button {
                manager.sortNewestFirst.toggle()
            } label: {
                Label(manager.sortNewestFirst ? "Newest first" : "Oldest first",
                      systemImage: manager.sortNewestFirst ? "arrow.down" : "arrow.up")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Change sort order")
            HStack(spacing: 4) {
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $manager.thumbnailSize, in: 90...280)
                    .frame(width: 110)
                    .controlSize(.small)
                Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
            }
            .help("Thumbnail size")
        }
    }

    private var selectMenu: some View {
        Group {
            Menu("Select") {
                Button("All  (⌘A)") { selectAll() }
                Button("All New  (⇧⌘A)") { selectNew() }
                Button("Invert Selection  (⇧⌘I)") { invertSelection() }
                Divider()
                Button("None  (Esc)") { clearSelection() }
                Divider()
                Button("Preview  (Space)") { openPreview() }
            }
            .fixedSize()
            .help("Click: select · ⌘-click: add/remove · ⇧-click: range · Double-click or Space: preview · Day header: select whole day")
            // Hidden buttons so the shortcuts work without opening the menu.
            Group {
                Button("", action: selectAll).keyboardShortcut("a", modifiers: .command)
                Button("", action: selectNew).keyboardShortcut("a", modifiers: [.command, .shift])
                Button("", action: invertSelection).keyboardShortcut("i", modifiers: [.command, .shift])
                Button("", action: clearSelection).keyboardShortcut(.escape, modifiers: [])
                Button("", action: openPreview).keyboardShortcut(.space, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Grid / empty states

    @ViewBuilder
    private var content: some View {
        if manager.selectedCamera == nil {
            placeholder(symbol: "cable.connector", title: "No device", detail: DeviceManager.idleStatus)
        } else if manager.accessRestricted {
            placeholder(symbol: "lock.iphone", title: "Device locked", detail: "Unlock it and keep it awake while browsing.")
        } else if !manager.catalogComplete {
            VStack(spacing: 10) {
                ProgressView(value: Double(manager.catalogPercent), total: 100)
                    .frame(width: 260)
                Text("Reading library… \(manager.catalogPercent)%").foregroundStyle(.secondary)
                Text("Large libraries can take a minute. Keep the device unlocked.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = manager.visibleGroups
            let size = CGFloat(manager.thumbnailSize)
            if groups.isEmpty {
                if manager.items.isEmpty {
                    placeholder(symbol: "photo.on.rectangle", title: "No photos or videos", detail: "")
                } else if manager.filteredCount == 0 {
                    placeholder(symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches the filters",
                                detail: "Change the type or date range, or click Clear Filters.")
                } else {
                    placeholder(symbol: "checkmark.circle", title: "Everything here is imported",
                                detail: "Uncheck “Hide imported” to see them.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.3), spacing: 10)],
                              spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.items) { item in
                                    TileView(item: item, selected: manager.selection.contains(item.id), size: size)
                                        .onAppear { manager.requestThumbnail(for: item) }
                                        .onTapGesture { click(item) }
                                        .contextMenu {
                                            Button("Preview") { anchor = item.id; openPreview() }
                                            Divider()
                                            Button("Select This Day") { selectDay(group, additive: false) }
                                            Button("Add This Day to Selection") { selectDay(group, additive: true) }
                                            Divider()
                                            Button("Select All New") { selectNew() }
                                            Button("Deselect All") { clearSelection() }
                                        }
                                }
                            } header: {
                                dayHeader(group)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        let ids = group.items.map(\.id)
        let selectedCount = ids.filter { manager.selection.contains($0) }.count
        let allSelected = selectedCount == ids.count
        return HStack(spacing: 8) {
            Text(group.day.map { Self.dayFormatter.string(from: $0) } ?? "Unknown date")
                .font(.subheadline.weight(.semibold))
            Text(selectedCount > 0 ? "\(selectedCount) of \(ids.count) selected" : "\(ids.count) items")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(allSelected ? "Deselect" : "Select") {
                if allSelected {
                    manager.selection.subtract(ids)
                } else {
                    manager.selection.formUnion(ids)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(manager.destination.path)
                    .lineLimit(1).truncationMode(.head)
                    .help(manager.destination.path)
                Button("Choose…") { manager.chooseDestination() }
                    .disabled(manager.isImporting)
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: manager.destination, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(manager.destination)
                }
                Button("Open Log") {
                    NSWorkspace.shared.open(ImportLog.url(in: manager.destination))
                }
                .disabled(!FileManager.default.fileExists(atPath: ImportLog.url(in: manager.destination).path))
                .help("Open “\(ImportLog.fileName)” — one row per file: what was copied, where, its dates, and any errors.")
                Spacer()
                settingsButton
            }

            settingsSummary

            HStack(spacing: 10) {
                if manager.isImporting {
                    ProgressView(value: Double(manager.progressDone), total: Double(max(manager.progressTotal, 1)))
                        .frame(maxWidth: 280)
                    Text("\(manager.progressDone)/\(manager.progressTotal)  \(manager.currentFile ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel") { manager.cancelImport() }
                } else if let summary = manager.lastSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Import Selected (\(manager.selection.count))") {
                    startImport(manager.items.filter { manager.selection.contains($0.id) })
                }
                .disabled(manager.isImporting || manager.selection.isEmpty)
                Button("Import All New (\(manager.newItems.count))") {
                    startImport(manager.newItems)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(manager.isImporting || manager.newItems.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        } else {
            Button {
                _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
        }
    }

    /// One line showing the settings that shape this import.
    private var settingsSummary: some View {
        var parts: [String] = []
        if manager.useDateSubfolders { parts.append("Date folders") }
        parts.append(manager.renameMode.shortLabel)
        if manager.skipExisting { parts.append("Skips already imported") }
        if manager.skipLivePhotoVideos { parts.append("Skips Live Photo videos") }
        if manager.screenshotsFolder { parts.append("Screenshots folder") }
        parts.append("\(manager.parallelDownloads) parallel")
        return HStack(spacing: 4) {
            Text(parts.joined(separator: " · "))
                .foregroundStyle(.secondary)
            if manager.deleteAfterImport {
                Text("· Deletes from device after import")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    // MARK: Selection (Finder-style)

    private func click(_ item: PhotoItem) {
        // Double-click previews, like Space. Reading the click count from the event (rather than
        // adding a second, count-2 tap gesture) keeps single clicks instant.
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            anchor = item.id
            openPreview()
            return
        }
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            let ordered = manager.visibleItems
            if let anchor,
               let a = manager.visibleIndex[anchor],
               let b = manager.visibleIndex[item.id] {
                let range = ordered[min(a, b)...max(a, b)].map(\.id)
                if flags.contains(.command) {
                    manager.selection.formUnion(range)
                } else {
                    manager.selection = Set(range)
                }
            } else {
                manager.selection.insert(item.id)
                anchor = item.id
            }
        } else if flags.contains(.command) {
            if manager.selection.contains(item.id) {
                manager.selection.remove(item.id)
            } else {
                manager.selection.insert(item.id)
            }
            anchor = item.id
        } else {
            manager.selection = [item.id]
            anchor = item.id
        }
    }

    private func selectAll() {
        manager.selection = Set(manager.visibleItems.map(\.id))
    }

    private func selectNew() {
        manager.selection = Set(manager.newItems.map(\.id)).filter { manager.visibleIndex[$0] != nil }
    }

    private func invertSelection() {
        let visible = Set(manager.visibleItems.map(\.id))
        manager.selection = visible.subtracting(manager.selection)
    }

    private func clearSelection() {
        manager.selection = []
        anchor = nil
    }

    private func selectDay(_ group: DayGroup, additive: Bool) {
        let ids = Set(group.items.map(\.id))
        manager.selection = additive ? manager.selection.union(ids) : ids
    }

    /// Previews the last-clicked item, else the first selected, else the first shown.
    private func openPreview() {
        guard manager.catalogComplete, !manager.visibleItems.isEmpty else { return }
        if let anchor, manager.visibleIndex[anchor] != nil {
            previewID = anchor
        } else if let first = manager.visibleItems.first(where: { manager.selection.contains($0.id) }) {
            previewID = first.id
        } else {
            previewID = manager.visibleItems.first?.id
        }
        showPreview = true
    }

    // MARK: Actions

    private func startImport(_ list: [PhotoItem]) {
        guard !list.isEmpty else { return }
        pendingImport = list
        let (needed, available) = manager.spaceCheck(for: list)
        let margin: Int64 = 500_000_000 // keep ~500 MB spare
        if let available, needed + margin > available {
            let fmt = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
            spaceMessage = "This import needs about \(fmt(needed)), but only \(fmt(available)) is free on the destination drive."
            spaceAlert = true
            return
        }
        proceed(list)
    }

    private func proceed(_ list: [PhotoItem]) {
        if manager.deleteAfterImport && !manager.askBeforeDeleting {
            // No review sheet afterwards, so confirm up front.
            pendingImport = list
            confirmDelete = true
        } else {
            // With review on, the exact delete list is shown after the import.
            run(list, delete: manager.deleteAfterImport)
        }
    }

    private func run(_ list: [PhotoItem], delete: Bool) {
        Task { await manager.importItems(list, deleteFromDevice: delete) }
    }

    private func icon(for cam: ICCameraDevice) -> String {
        let kind = (cam.name ?? "").lowercased()
        if kind.contains("ipad") { return "ipad" }
        if kind.contains("iphone") || kind.contains("ipod") { return "iphone" }
        return "camera"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, yyyy"
        return f
    }()
}

// MARK: - Tile

struct TileView: View {
    @ObservedObject var item: PhotoItem
    let selected: Bool
    let size: CGFloat

    /// Stamps are floating local capture times, so show them in UTC.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                if let img = item.thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(height: size * 0.85)
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Label(durationText, systemImage: item.isLivePhotoVideo ? "livephoto" : "video.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color.white))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) { badge.padding(6) }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.stamp.map { Self.timeFormatter.string(from: $0) } ?? "No date")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .opacity(item.isDone && !selected ? 0.55 : 1)
        .contentShape(Rectangle())
        .help(item.failureMessage ?? item.name)
    }

    @ViewBuilder
    private var badge: some View {
        switch item.state {
        case .imported, .alreadyImported:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.green).font(.title3)
                .background(Circle().fill(Color.white))
                .help("Already in destination")
        case .importing:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "clock.fill")
                .foregroundStyle(Color.gray)
                .background(Circle().fill(Color.white))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red).font(.title3)
        case .new:
            EmptyView()
        }
    }

    private var durationText: String {
        let total = Int(item.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

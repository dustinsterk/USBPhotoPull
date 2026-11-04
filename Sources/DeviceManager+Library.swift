import AppKit
import ImageCaptureCore

/// The library shown in the grid: building items, filters, cached views, "already imported" state.
extension DeviceManager {
    func makeItems(_ cameraItems: [ICCameraItem]) -> [PhotoItem] {
        cameraItems
            .compactMap { $0 as? ICCameraFile }
            .filter { !Self.sidecarExtensions.contains((($0.name ?? "") as NSString).pathExtension.lowercased()) }
            .filter { itemIndex[ObjectIdentifier($0)] == nil }
            .map(PhotoItem.init(file:))
    }

    func setItems(_ newItems: [PhotoItem]) {
        // The phone re-reports a file when it changes while connected (e.g. editing a photo adds an
        // .AAE). Keep one entry per file — the most recent listing, which is current and has the
        // new sidecars — so it isn't downloaded twice and the stale copy isn't used.
        var seenKeys = Set<String>()
        let unique = newItems.reversed().filter { seenKeys.insert($0.matchKey).inserted }
        if unique.count < newItems.count {
            DeviceLog.write("Ignored \(newItems.count - unique.count) duplicate listing(s) from the device")
        }
        items = sorted(unique)
        // A Live Photo is a still + a short movie sharing the same base name (IMG_1234.HEIC + IMG_1234.MOV).
        let stillNames = Set(items.filter { !$0.isVideo }.map(\.baseKey))
        for item in items where item.isVideo {
            item.isLivePhotoVideo = stillNames.contains(item.baseKey) && item.duration < 6
        }
        itemIndex = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        selection = selection.filter { itemIndex[$0] != nil }
        recomputeViews()
        refreshImportedState()
    }

    /// Undated items always go last.
    func sorted(_ list: [PhotoItem]) -> [PhotoItem] {
        let newest = sortNewestFirst
        return list.sorted { a, b in
            switch (a.captureDate, b.captureDate) {
            case let (x?, y?): return newest ? x > y : x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name < b.name
            }
        }
    }

    func resort() {
        items = sorted(items)
        recomputeViews()
    }

    /// Cached thumbnail if there is one (memory, then disk); otherwise ask the phone.
    /// A request the phone hasn't answered within 10 s may be retried.
    func requestThumbnail(for item: PhotoItem) {
        guard item.thumbnail == nil else { return }
        if let at = item.thumbnailRequestedAt, Date().timeIntervalSince(at) < 10 { return }
        item.thumbnailRequestedAt = Date()
        ThumbnailCache.load(item.matchKey) { [weak item] img in
            guard let item, item.thumbnail == nil else { return }
            if let img {
                item.thumbnail = img
            } else {
                item.file.requestThumbnail()
            }
        }
    }

    func isSkippedLive(_ item: PhotoItem) -> Bool {
        skipLivePhotoVideos && item.isLivePhotoVideo
    }

    /// Rebuilds the cached lists the UI reads. O(n); call after items, states or filters change.
    func recomputeViews() {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: min(dateFrom, dateTo))
        let hi = cal.startOfDay(for: max(dateFrom, dateTo))
        let media = mediaFilter
        let byDate = dateFilterEnabled

        let filtered = items.filter { item in
            if isSkippedLive(item) { return false }
            if !media.matches(item) { return false }
            if byDate {
                guard let day = item.dayStart, day >= lo, day <= hi else { return false }
            }
            return true
        }
        let visible = hideImported ? filtered.filter { !$0.isDone } : filtered

        var groups: [DayGroup] = []
        for item in visible {
            if let last = groups.last, last.id == item.dayKey {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(DayGroup(id: item.dayKey, day: item.dayStart, items: [item]))
            }
        }

        var index: [ObjectIdentifier: Int] = [:]
        index.reserveCapacity(visible.count)
        for (i, item) in visible.enumerated() { index[item.id] = i }

        visibleIndex = index
        visibleItems = visible
        visibleGroups = groups
        filteredCount = filtered.count
        var counts: [MediaFilter: Int] = [:]
        for item in items where !isSkippedLive(item) {
            for f in MediaFilter.allCases where f.matches(item) { counts[f, default: 0] += 1 }
        }
        kindCounts = counts
        newItems = filtered.filter { item in
            switch item.state {
            case .new, .failed: return true
            default: return false
            }
        }
    }

    func filtersChanged() {
        recomputeViews()
        selection = selection.filter { visibleIndex[$0] != nil }
    }

    /// Marks items that already have a verified copy in the destination.
    func refreshImportedState() {
        let mode = renameMode
        let skipLive = skipLivePhotoVideos
        // Snapshot on the main thread; device objects aren't touched in the background.
        let base = destination
        let snapshot: [(ObjectIdentifier, String, Int64, Date?, [(String, Int64)], URL)] = items.map { item in
            let sidecars: [(String, Int64)] = (item.file.sidecarFiles ?? []).compactMap { sc in
                guard let file = sc as? ICCameraFile, let name = file.name else { return nil }
                let ext = (name as NSString).pathExtension
                if skipLive && Self.movieExtensions.contains(ext.lowercased()) { return nil }
                return (ext, Int64(file.fileSize))
            }
            return (item.id, Self.destinationName(for: item.name, date: item.stamp, mode: mode),
                    item.size, item.stamp, sidecars, root(for: item, base: base))
        }
        let subfolders = useDateSubfolders
        DispatchQueue.global(qos: .userInitiated).async {
            var existing = Set<ObjectIdentifier>()
            for (id, name, size, date, sidecars, itemRoot) in snapshot {
                let folder = Self.folder(base: itemRoot, date: date, subfolders: subfolders)
                guard let main = Self.existingCopy(in: folder, name: name, size: size) else { continue }
                let stem = main.deletingPathExtension().lastPathComponent
                let complete = sidecars.allSatisfy { ext, scSize in
                    Self.existingCopy(in: folder, name: ext.isEmpty ? stem : stem + "." + ext, size: scSize) != nil
                }
                if complete { existing.insert(id) }
            }
            DispatchQueue.main.async {
                for item in self.items {
                    switch item.state {
                    case .queued, .importing: continue
                    default: item.state = existing.contains(item.id) ? .alreadyImported : .new
                    }
                }
                self.recomputeViews()
            }
        }
    }

    /// Bytes the import will write (skipping what will be skipped) and the space free on the destination volume.
    func spaceCheck(for list: [PhotoItem]) -> (needed: Int64, available: Int64?) {
        var needed: Int64 = 0
        for item in list where !isSkippedLive(item) && !(skipExisting && item.state == .alreadyImported) {
            needed += max(item.size, 0)
            for case let sidecar as ICCameraFile in item.file.sidecarFiles ?? [] {
                let ext = ((sidecar.name ?? "") as NSString).pathExtension.lowercased()
                if skipLivePhotoVideos && Self.movieExtensions.contains(ext) { continue }
                needed += max(Int64(sidecar.fileSize), 0)
            }
        }

        // Walk up to the nearest folder that exists (the destination may not be created yet).
        var probe = destination
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage
        let plain = values?.volumeAvailableCapacity.map { Int64($0) }
        let available: Int64? = (important == nil && plain == nil) ? nil : max(important ?? 0, plain ?? 0)
        return (needed, available)
    }
}

import AppKit
import ImageCaptureCore

/// Copying files from the device: parallel lanes, safe temp downloads, timeouts, sidecars, dates.
extension DeviceManager {
    func cancelImport() { cancelRequested = true }

    /// Child-task result; carries the item's index in the import list (Sendable).
    enum ItemResult: Sendable {
        case imported(Int, bytes: Int64)
        case skipped(Int)
        case failed
        case cancelled
    }

    @MainActor
    func importItems(_ list: [PhotoItem], deleteFromDevice: Bool) async {
        var seenKeys = Set<String>()
        let list = list.filter { !isSkippedLive($0) && seenKeys.insert($0.matchKey).inserted }
        guard !isImporting, let camera = selectedCamera, !list.isEmpty else { return }
        let base = destination
        let subfolders = useDateSubfolders
        let skip = skipExisting
        let mode = renameMode
        let lanes = min(max(parallelDownloads, 1), 4)

        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            lastSummary = "Can’t use destination folder: \(error.localizedDescription)"
            return
        }

        log = ImportLog(destination: base)
        logDevice = camera.name ?? "Device"

        // Keep the Mac awake for the whole import.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Importing photos from \(camera.name ?? "device")")

        if notifyWhenDone { Notifier.requestPermission() }
        DockProgress.shared.update(0)

        importingCamera = camera
        isImporting = true
        cancelRequested = false
        progressDone = 0
        progressTotal = list.count
        lastSummary = nil
        var imported = 0, skipped = 0, failed = 0
        var bytes: Int64 = 0
        var verifiedOnDisk: [ICCameraItem] = []
        let started = Date()

        for item in list where !(skip && item.state == .alreadyImported) { item.state = .queued }

        // Keep `lanes` downloads in flight; start the next as soon as one finishes.
        await withTaskGroup(of: ItemResult.self) { group in
            var queue = list.indices.makeIterator()
            for _ in 0..<lanes {
                if let index = queue.next() {
                    group.addTask { await self.importOne(at: index, of: list, base: base, subfolders: subfolders, skip: skip, mode: mode) }
                }
            }
            while let result = await group.next() {
                switch result {
                case .imported(let index, let n):
                    imported += 1; bytes += n; verifiedOnDisk.append(list[index].file)
                case .skipped(let index):
                    skipped += 1; verifiedOnDisk.append(list[index].file)
                case .failed:
                    failed += 1
                case .cancelled:
                    break
                }
                if case .cancelled = result {} else { progressDone += 1 }
                DockProgress.shared.update(Double(progressDone) / Double(max(progressTotal, 1)))
                recomputeViews()
                if !cancelRequested, let index = queue.next() {
                    group.addTask { await self.importOne(at: index, of: list, base: base, subfolders: subfolders, skip: skip, mode: mode) }
                }
            }
        }

        // Anything never started goes back to its normal state.
        for item in list where item.state == .queued { item.state = .new }

        // Remove hidden temp folders (and any partial files left in them).
        for folder in tempFolders { try? FileManager.default.removeItem(at: folder) }
        tempFolders.removeAll()

        let cancelled = cancelRequested
        let elapsed = Date().timeIntervalSince(started)
        currentFile = nil
        var summary = "Imported \(imported)"
        if skipped > 0 { summary += ", skipped \(skipped) already imported" }
        if failed > 0 { summary += ", \(failed) failed (see the import log)" }
        if bytes > 0 {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let rate = Double(bytes) / max(elapsed, 0.001) / 1_000_000
            summary += String(format: " — %@ in %.1f s (%.1f MB/s, %ld parallel)", size, elapsed, rate, lanes)
        }
        if cancelled { summary += " — stopped" }

        if deleteFromDevice && !cancelled && !verifiedOnDisk.isEmpty && camera === selectedCamera {
            let plan = deletionPlan(for: verifiedOnDisk, base: base)
            for (name, reason) in plan.kept {
                log?.append(.init(device: logDevice, deviceFile: name, result: "Kept on device", details: reason))
            }
            if !plan.entries.isEmpty {
                if askBeforeDeleting {
                    deleteReview = DeleteReview(entries: plan.entries, kept: plan.kept,
                                                destination: base, device: logDevice, camera: camera)
                    summary += ". \(plan.entries.count) ready to delete — waiting for your review"
                } else {
                    performDelete(plan.entries, destination: base, device: logDevice, camera: camera)
                    summary += ". Deleting \(plan.entries.count) from device…"
                }
            }
            if !plan.kept.isEmpty {
                summary += " Kept \(plan.kept.count) on the device (see log)."
            }
        }

        log?.append(.init(device: logDevice, deviceFile: "", bytes: bytes > 0 ? bytes : nil,
                          result: "Summary", details: summary))
        log?.close()
        log = nil

        ProcessInfo.processInfo.endActivity(activity)
        DockProgress.shared.clear()
        if notifyWhenDone {
            if let review = deleteReview {
                Notifier.importFinished(title: "Import finished — review deletes",
                                        body: "Review \(review.entries.count) items to delete from \(logDevice).")
            } else {
                Notifier.importFinished(title: cancelled ? "Import stopped" : (failed > 0 ? "Import finished with errors" : "Import finished"),
                                        body: summary)
            }
        }
        importingCamera = nil
        lastSummary = summary
        isImporting = false
        recomputeViews()
    }

    @MainActor
    func importOne(at index: Int, of list: [PhotoItem], base: URL, subfolders: Bool,
                           skip: Bool, mode: RenameMode) async -> ItemResult {
        let item = list[index]
        if cancelRequested { return .cancelled }

        var row = ImportLog.Row(device: logDevice, deviceFile: item.name, bytes: item.size,
                                captureDate: item.stamp, result: "")

        // Cheap pre-check with the best-known capture time, so already-imported files aren't downloaded.
        if skip, let existing = existingDestination(for: item, base: base, subfolders: subfolders, mode: mode) {
            item.state = .alreadyImported
            row.savedAs = ImportLog.relativePath(existing, to: base)
            row.result = "Skipped"
            row.details = "Already in destination (same name and size)"
            log?.append(row)
            return await completeSidecars(for: item, index: index, existing: existing, base: base)
        }

        item.state = .importing
        currentFile = item.name
        var temp: URL?
        do {
            let received = try await downloadToTemp(item.file, base: base, name: item.name, expectedSize: item.size)
            temp = received

            // The file's own metadata gives the local time where it was taken (correct when travelling).
            let capture = await MetadataPreserver.captureTime(of: received, isVideo: item.isVideo)
            if !item.isVideo { item.livePhotoID = MetadataPreserver.livePhotoID(of: received) }
            let stampChanged = capture?.wallClock != nil && capture?.wallClock != item.stamp
            if let wall = capture?.wallClock { item.localStamp = wall }
            row.captureDate = item.stamp

            if skip, stampChanged,
               let existing = existingDestination(for: item, base: base, subfolders: subfolders, mode: mode) {
                try? FileManager.default.removeItem(at: received)
                item.state = .alreadyImported
                row.savedAs = ImportLog.relativePath(existing, to: base)
                row.result = "Skipped"
                row.details = "Already in destination (found after reading the capture time)"
                log?.append(row)
                return await completeSidecars(for: item, index: index, existing: existing, base: base)
            }

            let folder = Self.folder(base: root(for: item, base: base), date: item.stamp, subfolders: subfolders)
            let wanted = Self.destinationName(for: item.name, date: item.stamp, mode: mode)
            let url = try place(received, in: folder, as: wanted)
            temp = nil

            let dates = applyDates(for: item.file, capture: capture, at: url)
            let onDisk = Self.sizeOfFile(url) ?? 0
            row.savedAs = ImportLog.relativePath(url, to: base)
            row.bytes = onDisk
            row.dates = dates
            row.result = "Imported"
            var notes: [String] = []
            if dates == nil { notes.append("No capture date found; Finder dates left as import time") }
            if url.lastPathComponent != wanted { notes.append("Renamed to avoid a name clash") }
            if stampChanged { notes.append("Placed by local capture time") }
            row.details = notes.joined(separator: "; ")
            log?.append(row)

            let sidecarBytes = await downloadSidecars(of: item.file, mainFile: url, folder: folder,
                                                      base: base, fallbackDates: dates)
            item.state = .imported
            return .imported(index, bytes: onDisk + sidecarBytes)
        } catch {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            item.state = .failed(error.localizedDescription)
            row.result = "Failed"
            row.details = error.localizedDescription
            log?.append(row)
            return .failed
        }
    }

    /// The main file is already there; fetch any of its sidecars that aren't
    /// (e.g. Live Photo videos after "Skip Live Photo videos" was turned off).
    @MainActor
    func completeSidecars(for item: PhotoItem, index: Int, existing: URL, base: URL) async -> ItemResult {
        if !item.isVideo && item.livePhotoID == nil {
            item.livePhotoID = MetadataPreserver.livePhotoID(of: existing)
        }
        let added = await downloadSidecars(of: item.file, mainFile: existing,
                                           folder: existing.deletingLastPathComponent(), base: base,
                                           fallbackDates: MetadataPreserver.dates(for: item.file, capture: nil))
        if added > 0 {
            item.state = .imported
            return .imported(index, bytes: added)
        }
        return .skipped(index)
    }

    func existingDestination(for item: PhotoItem, base: URL, subfolders: Bool, mode: RenameMode) -> URL? {
        let folder = Self.folder(base: root(for: item, base: base), date: item.stamp, subfolders: subfolders)
        let name = Self.destinationName(for: item.name, date: item.stamp, mode: mode)
        return Self.existingCopy(in: folder, name: name, size: item.size)
    }

    /// Downloads into a hidden temp folder at the destination root and verifies the size.
    /// A failed or interrupted transfer never leaves a partial file in your folders.
    @MainActor
    func downloadToTemp(_ file: ICCameraFile, base: URL, name: String, expectedSize: Int64) async throws -> URL {
        let fm = FileManager.default
        let temp = base.appendingPathComponent(Self.tempFolderName, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        tempFolders.insert(temp)

        let ext = (name as NSString).pathExtension
        let tempName = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let tempURL = temp.appendingPathComponent(tempName)
        var received = tempURL
        do {
            let saved = try await download(file, to: temp, as: tempName, expectedSize: expectedSize, watching: tempURL)
            received = resolveSavedURL(saved, folder: temp, fallbackName: tempName)
            guard let onDisk = Self.sizeOfFile(received) else {
                throw ImportError("Downloaded file not found")
            }
            if expectedSize > 0 && onDisk != expectedSize {
                throw ImportError("Incomplete transfer (device \(expectedSize) B, received \(onDisk) B)")
            }
            return received
        } catch {
            try? fm.removeItem(at: received)
            if received != tempURL { try? fm.removeItem(at: tempURL) }
            throw error
        }
    }

    /// Moves a verified temp file to its final, non-clashing name. Synchronous, so parallel lanes can't collide.
    @MainActor
    func place(_ temp: URL, in folder: URL, as wanted: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let finalURL = folder.appendingPathComponent(Self.uniqueName(in: folder, name: wanted))
        try fm.moveItem(at: temp, to: finalURL)
        return finalURL
    }

    /// One outstanding device download; resumed exactly once by completion, timeout, or disconnect.
    final class PendingDownload {
        var continuation: CheckedContinuation<String?, Error>?
        init(_ continuation: CheckedContinuation<String?, Error>) { self.continuation = continuation }
        var isFinished: Bool { continuation == nil }
        func finish(_ result: Result<String?, Error>) {
            guard let c = continuation else { return }
            continuation = nil
            c.resume(with: result)
        }
    }

    @MainActor
    func download(_ file: ICCameraFile, to folder: URL, as name: String,
                          expectedSize: Int64, watching partial: URL) async throws -> String? {
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: folder,
            .saveAsFilename: name,
            .overwrite: false,
            .sidecarFiles: false, // sidecars are fetched individually so Live Photo movies can be skipped
        ]
        let id = UUID()
        defer { activeDownloads[id] = nil }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            let pending = PendingDownload(cont)
            activeDownloads[id] = pending
            let progress = file.requestDownload(options: options) { savedName, error in
                DispatchQueue.main.async {
                    if let error {
                        pending.finish(.failure(error))
                    } else {
                        pending.finish(.success(savedName))
                    }
                }
            }
            startWatchdog(for: pending, progress: progress, partial: partial, expectedSize: expectedSize)
        }
    }

    /// Fails a download that stops moving for 90 s, or that never finishes within a generous
    /// size-based ceiling (2 min + 1 s per MB), so a stuck device can't hang the import.
    func startWatchdog(for pending: PendingDownload, progress: Progress?, partial: URL, expectedSize: Int64) {
        let stallLimit: TimeInterval = 90
        let ceiling: TimeInterval = 120 + Double(max(expectedSize, 0)) / 1_000_000
        let start = Date()
        var lastSeen: Int64 = -1
        var lastChange = Date()
        var sawMovement = false

        func tick() {
            guard !pending.isFinished else { return }
            let seen = max(progress?.completedUnitCount ?? 0, Self.sizeOfFile(partial) ?? 0)
            if seen != lastSeen {
                if lastSeen >= 0 && seen > lastSeen { sawMovement = true }
                lastSeen = seen
                lastChange = Date()
            }
            let now = Date()
            let stalled = sawMovement && now.timeIntervalSince(lastChange) > stallLimit
            if stalled || now.timeIntervalSince(start) > ceiling {
                progress?.cancel()
                pending.finish(.failure(ImportError(stalled ? "Transfer stalled — timed out" : "Transfer timed out")))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tick() }
    }

    func failActiveDownloads(_ message: String) {
        if isImporting { cancelRequested = true }
        for pending in activeDownloads.values {
            pending.finish(.failure(ImportError(message)))
        }
    }

    func resolveSavedURL(_ saved: String?, folder: URL, fallbackName: String) -> URL {
        if let saved, !saved.isEmpty {
            let url = saved.hasPrefix("/")
                ? URL(fileURLWithPath: saved)
                : folder.appendingPathComponent(saved)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return folder.appendingPathComponent(fallbackName)
    }

    @discardableResult
    func applyDates(for file: ICCameraFile, capture: MetadataPreserver.CaptureTime?, at url: URL,
                            fallback: MetadataPreserver.Dates? = nil) -> MetadataPreserver.Dates? {
        guard let dates = MetadataPreserver.dates(for: file, capture: capture) ?? fallback else { return nil }
        try? MetadataPreserver.apply(dates, to: url)
        return dates
    }

    /// Fetches sidecars (iPhone .AAE edits, and the Live Photo .MOV unless skipped) next to the
    /// media file, named to match it, with their dates preserved. Failures here are non-fatal.
    @MainActor
    func downloadSidecars(of file: ICCameraFile, mainFile: URL, folder: URL, base: URL,
                                  fallbackDates: MetadataPreserver.Dates?) async -> Int64 {
        var bytes: Int64 = 0
        let stem = (mainFile.lastPathComponent as NSString).deletingPathExtension
        for case let sidecar as ICCameraFile in file.sidecarFiles ?? [] {
            guard let scName = sidecar.name else { continue }
            let ext = (scName as NSString).pathExtension
            let isMovie = Self.movieExtensions.contains(ext.lowercased())
            let size = Int64(sidecar.fileSize)
            var row = ImportLog.Row(device: logDevice, deviceFile: scName, bytes: size,
                                    captureDate: (sidecar.exifCreationDate ?? sidecar.creationDate).map(MetadataPreserver.wallClockInCurrentZone),
                                    result: "", details: "Sidecar of \(file.name ?? "")")

            if isMovie && skipLivePhotoVideos {
                row.result = "Skipped"
                row.details = "Live Photo video of \(file.name ?? "") (Skip Live Photo videos is on)"
                log?.append(row)
                continue
            }

            let wanted = ext.isEmpty ? stem : stem + "." + ext
            if let existing = Self.existingCopy(in: folder, name: wanted, size: size) {
                row.savedAs = ImportLog.relativePath(existing, to: base)
                row.result = "Skipped"
                row.details += "; already in destination"
                log?.append(row)
                continue
            }
            do {
                let received = try await downloadToTemp(sidecar, base: base, name: wanted, expectedSize: size)
                var capture: MetadataPreserver.CaptureTime?
                if isMovie { capture = await MetadataPreserver.captureTime(of: received, isVideo: true) }
                let url = try place(received, in: folder, as: wanted)
                row.dates = applyDates(for: sidecar, capture: capture, at: url, fallback: fallbackDates)
                let onDisk = Self.sizeOfFile(url) ?? 0
                bytes += onDisk
                row.savedAs = ImportLog.relativePath(url, to: base)
                row.bytes = onDisk
                row.result = "Imported"
            } catch {
                row.result = "Failed"
                row.details += "; \(error.localizedDescription)"
            }
            log?.append(row)
        }
        return bytes
    }
}

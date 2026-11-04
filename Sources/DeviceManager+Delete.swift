import AppKit
import ImageCaptureCore

/// Deleting imported files from the device: what is safe to delete, the review step, results.
extension DeviceManager {
    /// Live Photos in `list` whose video won't be imported (setting on) but will be deleted with the photo.
    func liveVideosNotKept(in list: [PhotoItem]) -> Int {
        guard skipLivePhotoVideos else { return 0 }
        return list.filter { item in
            (item.file.sidecarFiles ?? []).contains {
                Self.movieExtensions.contains((($0.name ?? "") as NSString).pathExtension.lowercased())
            }
        }.count
    }

    /// Decides what can be deleted from the device. A photo is deleted together with its parts
    /// (Live Photo video, .AAE). The only thing that holds a delete back is the other half of a
    /// Live Photo that hasn't been imported — deleting one half would take the other with it.
    /// Companions are looked up among the library's own items by name (the raw device listing can
    /// contain stale duplicates and alternate renditions, which must not block deletes).
    @MainActor
    func deletionPlan(for verified: [ICCameraItem], base: URL)
        -> (entries: [DeleteEntry], kept: [(String, String)]) {
        var byBase: [String: [PhotoItem]] = [:]
        for item in items { byBase[item.baseKey, default: []].append(item) }
        let verifiedIDs = Set(verified.map { ObjectIdentifier($0) })
        func isSafe(_ item: PhotoItem) -> Bool { item.isDone || verifiedIDs.contains(item.id) }

        var entries: [DeleteEntry] = []
        var kept: [(String, String)] = []
        var seenFiles = Set<ObjectIdentifier>()

        for case let main as ICCameraFile in verified {
            guard let item = itemIndex[ObjectIdentifier(main)] else { continue }
            // Already included as the other half of an earlier entry's Live Photo.
            if seenFiles.contains(ObjectIdentifier(main)) { continue }
            var parts: [ICCameraItem] = [main] + (main.sidecarFiles ?? [])
            let linkedNames = Set(parts.compactMap { $0.name?.lowercased() })
            var blocker: String?

            // The other half of a Live Photo, if the device lists it separately.
            var seenNames = linkedNames
            for other in byBase[item.baseKey] ?? [] {
                let lower = other.name.lowercased()
                guard seenNames.insert(lower).inserted else { continue } // same file / duplicate
                guard Self.isLivePair(item, other) else { continue }     // unrelated file sharing a number
                if isSafe(other) || (other.isVideo && skipLivePhotoVideos) {
                    parts.append(other.file)
                    parts.append(contentsOf: other.file.sidecarFiles ?? [])
                } else {
                    blocker = "Its Live Photo \(other.isVideo ? "video" : "photo") \(other.name) hasn’t been imported"
                }
            }
            // A Live Photo still whose video the phone isn't offering yet (it can take a few minutes
            // after shooting). Deleting the still alone leaves the Live Photo on the phone, so wait.
            let hasMovie = parts.contains {
                Self.movieExtensions.contains((($0.name ?? "") as NSString).pathExtension.lowercased())
            }
            if blocker == nil && !item.isVideo && item.livePhotoID != nil && !hasMovie {
                blocker = "Live Photo whose video the phone isn’t offering yet (this can take a few minutes after taking it). Import again later to delete it."
            }
            if let blocker {
                kept.append((item.name, blocker))
                continue
            }
            var files: [ICCameraItem] = []
            for part in parts where seenFiles.insert(ObjectIdentifier(part)).inserted {
                files.append(part)
            }
            entries.append(DeleteEntry(item: item, files: files))
        }
        return (entries, kept)
    }

    /// Sends the delete request for these entries (every part of each item).
    @MainActor
    func performDelete(_ entries: [DeleteEntry], destination: URL, device: String, camera: ICCameraDevice) {
        var seen = Set<ObjectIdentifier>()
        let files = entries.flatMap(\.files).filter { seen.insert(ObjectIdentifier($0)).inserted }
        let names = Set(entries.map(\.item.name))
        pendingDelete = (destination: destination, device: device, camera: camera, names: names)
        deleteFailures = []
        DeviceLog.write("Delete requested: \(files.count) files for \(entries.count) items")
        _ = camera.requestDeleteFiles(files, deleteFailed: { [weak self] failures in
            let rows = failures.map { ("\($0.key.rawValue)", $0.value.name ?? "?") }
            DispatchQueue.main.async {
                for (reason, name) in rows { DeviceLog.write("Delete refused: \(name) — \(reason)") }
                self?.deleteFailures.append(contentsOf: rows)
            }
        }, completion: { [weak self] result, error in
            let counts = result.map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: ", ")
            let deleted = result.filter { "\($0.key.rawValue)".contains("Successful") }
                .flatMap { $0.value }
            let deletedIDs = Set(deleted.map { ObjectIdentifier($0) })
            let deletedNames = Set(deleted.compactMap { $0.name })
            DispatchQueue.main.async {
                DeviceLog.write("Delete finished: \(counts)\(error.map { " error: \($0.localizedDescription)" } ?? "")")
                self?.deleteFinished(error: error, deletedIDs: deletedIDs, deletedNames: deletedNames)
            }
        })
    }

    /// Review sheet: delete everything except the unticked items.
    @MainActor
    func confirmDeleteReview(excluding excluded: Set<ObjectIdentifier>) {
        guard let review = deleteReview else { return }
        deleteReview = nil
        let chosen = review.entries.filter { !excluded.contains($0.item.id) }
        let skipped = review.entries.filter { excluded.contains($0.item.id) }
        if let log = ImportLog(destination: review.destination) {
            for entry in skipped {
                log.append(.init(device: review.device, deviceFile: entry.item.name,
                                 result: "Kept on device", details: "You chose to keep it"))
            }
            log.close()
        }
        guard review.camera === selectedCamera else {
            replaceReviewNote(with: "The phone was disconnected, so nothing was deleted.")
            return
        }
        guard !chosen.isEmpty else {
            replaceReviewNote(with: "Kept all \(review.entries.count) on the device.")
            return
        }
        replaceReviewNote(with: "Deleting \(chosen.count) from device…")
        performDelete(chosen, destination: review.destination, device: review.device, camera: review.camera)
    }

    /// Review sheet: keep everything on the device.
    @MainActor
    func keepAllFromReview() {
        guard let review = deleteReview else { return }
        deleteReview = nil
        if let log = ImportLog(destination: review.destination) {
            log.append(.init(device: review.device, deviceFile: "", result: "Kept on device",
                             details: "You chose Keep All (\(review.entries.count) items)"))
            log.close()
        }
        replaceReviewNote(with: "Kept all \(review.entries.count) on the device.")
    }

    func replaceReviewNote(with note: String) {
        if let s = lastSummary, let range = s.range(of: " ready to delete — waiting for your review") {
            // "…. N ready to delete — waiting…" → "…. <note>"
            let head = s[..<range.lowerBound]
            let cut = head.range(of: ". ", options: .backwards)?.upperBound ?? head.endIndex
            lastSummary = String(s[..<cut]) + note + String(s[range.upperBound...])
        } else {
            lastSummary = (lastSummary ?? "") + " " + note
        }
    }

    /// A still and a ≤6 s movie with the same base name, captured within 2 s of each other.
    static func isLivePair(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        guard a.isVideo != b.isVideo else { return false }
        let movie = a.isVideo ? a : b
        guard movie.duration > 0, movie.duration <= 6 else { return false }
        guard let da = a.captureDate, let db = b.captureDate else { return false }
        return abs(da.timeIntervalSince(db)) <= 2
    }

    /// Called once per delete (by the completion block or the delegate, whichever comes first).
    func deleteFinished(error: Error?, deletedIDs: Set<ObjectIdentifier>, deletedNames: Set<String>) {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil

        let gone = pending.names.intersection(deletedNames)
        let notGone = pending.names.subtracting(deletedNames)
        var note: String
        if notGone.isEmpty && error == nil {
            note = "Deleted \(gone.count) from device."
        } else {
            note = "Deleted \(gone.count) of \(pending.names.count) from device"
            if !notGone.isEmpty {
                note += "; the phone kept " + notGone.sorted().prefix(5).joined(separator: ", ")
                    + (notGone.count > 5 ? "…" : "")
            }
            if let error { note += " (\(error.localizedDescription))" }
            note += "."
        }

        if let log = ImportLog(destination: pending.destination) {
            log.append(.init(device: pending.device, deviceFile: "",
                             result: notGone.isEmpty ? "Deleted from device" : "Delete incomplete", details: note))
            for (reason, name) in deleteFailures {
                log.append(.init(device: pending.device, deviceFile: name, result: "Device refused", details: reason))
            }
            log.close()
        }
        if let s = lastSummary, let range = s.range(of: ". Deleting") {
            lastSummary = String(s[..<range.lowerBound]) + ". " + note
        } else {
            lastSummary = (lastSummary ?? "") + " " + note
        }

        // Take deleted files out of the grid now (the device's own listing can lag behind).
        if !deletedIDs.isEmpty {
            items.removeAll { deletedIDs.contains($0.id) }
            for id in deletedIDs { itemIndex[id] = nil }
            selection.subtract(deletedIDs)
            recomputeViews()
            deviceStatus = "\(items.count) items on \(selectedCamera?.name ?? "device")"
        }
    }
}

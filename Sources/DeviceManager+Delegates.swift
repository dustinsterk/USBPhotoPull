import AppKit
import ImageCaptureCore

// MARK: - ICDeviceBrowserDelegate

extension DeviceManager: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        DeviceLog.write("Device found: \(device.name ?? "?") (\(type(of: device))), moreComing=\(moreComing)")
        guard let cam = device as? ICCameraDevice else { return }
        warmupPending = true
        emptyRetries = 0
        if !cameras.contains(cam) { cameras.append(cam) }
        DispatchQueue.main.async {
            if self.selectedCamera == nil { self.selectedCamera = cam }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        DeviceLog.write("Device removed: \(device.name ?? "?")")
        deviceWentAway(device)
    }
}

// MARK: - ICCameraDeviceDelegate

extension DeviceManager: ICCameraDeviceDelegate {
    // ICDeviceDelegate
    func didRemove(_ device: ICDevice) {
        deviceWentAway(device)
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        DeviceLog.write("Session opened on \(device.name ?? "?")\(error.map { " with error: \($0.localizedDescription)" } ?? " OK")")
        guard device === selectedCamera else { return }
        if let error {
            deviceStatus = "Couldn’t open \(device.name ?? "device"): \(error.localizedDescription) — retrying…"
            if let cam = device as? ICCameraDevice { checkSessionProgress(cam) }
        } else {
            deviceStatus = "Reading library… (keep the device unlocked)"
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        DeviceLog.write("Session closed on \(device.name ?? "?")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if let done = closeForQuit {
            closeForQuit = nil
            done()
        }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        DeviceLog.write("Device ready: \(device.name ?? "?")")
    }

    // ICCameraDeviceDelegate
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let count = (device.mediaFiles ?? []).count
        DeviceLog.write("Catalog complete: \(count) files")
        guard device === selectedCamera else { return }
        let reconnect = { (why: String) in
            DeviceLog.write(why)
            self.reloadDevice(keepSelection: true)
            self.deviceStatus = "Reading library…"
        }
        if warmupPending && !isImporting {
            warmupPending = false
            reconnect("First catalog after connecting — reconnecting once for the full library")
            return
        }
        if count == 0 && emptyRetries < 2 && !isImporting {
            emptyRetries += 1
            reconnect("Empty catalog — reconnecting (\(emptyRetries) of 2)")
            return
        }
        // Much smaller than the last full library from this device? Probably partial — try again.
        let known = defaults.integer(forKey: lastCountKey(device))
        if known > 0 && Double(count) < Double(known) * 0.9 && lowCountRetries < 2 && !isImporting {
            lowCountRetries += 1
            reconnect("Catalog has \(count) files, expected about \(known) — reconnecting (\(lowCountRetries) of 2)")
            return
        }
        emptyRetries = 0
        lowCountRetries = 0
        deviceStatus = "Reading library… \(count) files"
        settleCatalog(device, lastCount: count, stableTicks: 0, ticks: 0)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard camera === selectedCamera, catalogComplete else { return }
        let added = makeItems(items)
        guard !added.isEmpty else { return }
        setItems(self.items + added)
        deviceStatus = "\(self.items.count) items on \(camera.name ?? "device")"
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        guard camera === selectedCamera else { return }
        let removed = Set(items.map { ObjectIdentifier($0) })
        guard !removed.isEmpty else { return }
        self.items.removeAll { removed.contains($0.id) }
        for id in removed { itemIndex[id] = nil }
        selection.subtract(removed)
        recomputeViews()
        deviceStatus = "\(self.items.count) items on \(camera.name ?? "device")"
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        guard let thumbnail, let photo = itemIndex[ObjectIdentifier(item)] else { return }
        photo.thumbnail = ThumbnailCache.store(thumbnail, key: photo.matchKey)
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        DeviceLog.write("Access restricted (device locked)")
        guard device === selectedCamera else { return }
        accessRestricted = true
        deviceStatus = "Unlock \(device.name ?? "your device") to see its photos."
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        DeviceLog.write("Access restriction removed (device unlocked)")
        guard device === selectedCamera else { return }
        accessRestricted = false
        deviceStatus = catalogComplete ? "\(items.count) items on \(device.name ?? "device")" : "Reading library…"
    }

    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {
        // Handled by the completion block passed to requestDeleteFiles, which reports per-file results.
    }

}

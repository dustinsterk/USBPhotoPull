import AppKit
import ImageCaptureCore

/// Device discovery, the session with the phone, and loading its library (catalog).
extension DeviceManager {
    func start() {
        guard !started else { return }
        started = true
        DeviceLog.write("App started — browsing for devices")
        startBrowser()
    }

    func startBrowser() {
        browser.delegate = self
        let raw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        let mask: ICDeviceTypeMask? = ICDeviceTypeMask(rawValue: raw)
        if let mask { browser.browsedDeviceTypeMask = mask }
        // Authorization prompts are iOS-only; on macOS the browser can start directly.
        browser.start()
    }

    func shutdown() {
        clearPreviewCache()
        if let cam = selectedCamera, cam.hasOpenSession { cam.requestCloseSession() }
        browser.stop()
    }

    func switchCamera(from old: ICCameraDevice?) {
        if let old, old.hasOpenSession { old.requestCloseSession() }
        resetLibraryState()
        guard let cam = selectedCamera else {
            deviceStatus = Self.idleStatus
            return
        }
        openAttempts = 0
        openSession(cam)
    }

    /// Close and reopen the current device (⌘R), e.g. when the library didn't load.
    func reloadDevice(keepSelection: Bool = true) {
        guard let cam = selectedCamera, !isImporting, deleteReview == nil else { return }
        if keepSelection && !selection.isEmpty {
            reselectKeys = Set(items.filter { selection.contains($0.id) }.map(\.matchKey))
        }
        let summary = lastSummary
        resetLibraryState()
        lastSummary = summary
        openAttempts = 0
        deviceStatus = "Reconnecting to \(cam.name ?? "device")…"
        if cam.hasOpenSession { cam.requestCloseSession() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, cam === self.selectedCamera else { return }
            self.openSession(cam)
        }
    }

    func openSession(_ cam: ICCameraDevice) {
        openAttempts += 1
        cam.delegate = self
        deviceStatus = "Opening \(cam.name ?? "device")…"
        DeviceLog.write("Open session on \(cam.name ?? "?") (attempt \(openAttempts)); hasOpenSession=\(cam.hasOpenSession)")
        lastLoggedPercent = -1
        cam.requestOpenSession()

        catalogTimer?.invalidate()
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, let cam = self.selectedCamera, !self.catalogComplete else { timer.invalidate(); return }
            self.catalogPercent = cam.contentCatalogPercentCompleted
            if self.catalogPercent / 10 != self.lastLoggedPercent / 10 {
                self.lastLoggedPercent = self.catalogPercent
                DeviceLog.write("Catalog \(self.catalogPercent)%")
            }
        }
        scheduleSessionCheck(cam)
    }

    func scheduleSessionCheck(_ cam: ICCameraDevice) {
        sessionWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkSessionProgress(cam) }
        sessionWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// If the device hasn't started cataloguing after 10 s, close and reopen the session (up to 3 tries).
    func checkSessionProgress(_ cam: ICCameraDevice) {
        guard cam === selectedCamera, !catalogComplete else { return }
        if accessRestricted || cam.contentCatalogPercentCompleted > 0 {
            scheduleSessionCheck(cam) // locked or making progress: keep waiting
            return
        }
        DeviceLog.write("No catalog progress after 10 s (attempt \(openAttempts), restricted=\(accessRestricted), percent=\(cam.contentCatalogPercentCompleted))")
        guard openAttempts < 3 else {
            if !browserRestarted {
                restartDiscovery()
            } else {
                deviceStatus = "Couldn’t read the library. Unlock the iPhone, then click Reload (⌘R), or unplug and reconnect it."
                DeviceLog.write("Giving up after retries")
            }
            return
        }
        deviceStatus = "No response from \(cam.name ?? "device") — retrying (\(openAttempts + 1) of 3)…"
        if cam.hasOpenSession { cam.requestCloseSession() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, cam === self.selectedCamera, !self.catalogComplete else { return }
            self.openSession(cam)
        }
    }

    /// Stops and restarts device discovery so the device is re-enumerated from scratch,
    /// like unplugging and reconnecting it. Done automatically at most once per launch.
    func restartDiscovery() {
        browserRestarted = true
        DeviceLog.write("Restarting device discovery")
        deviceStatus = "Reconnecting to the device from scratch…"
        if let cam = selectedCamera, cam.hasOpenSession { cam.requestCloseSession() }
        browser.stop()
        browser.delegate = nil
        selectedCamera = nil
        cameras = []
        // A fresh browser instance re-enumerates more reliably than restarting the old one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.browser = ICDeviceBrowser()
            self.startBrowser()
        }
        rediscoveryWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.cameras.isEmpty else { return }
            DeviceLog.write("Device not found again after restarting discovery")
            self.deviceStatus = "Lost the connection to the phone. Unplug it and plug it back in."
        }
        rediscoveryWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: work)
    }

    /// Closes the device session cleanly before quitting; a session left open by a quitting app
    /// can leave the device stuck for the next launch until it's replugged.
    func prepareToQuit(_ done: @escaping () -> Void) {
        guard let cam = selectedCamera, cam.hasOpenSession else { done(); return }
        DeviceLog.write("Closing session before quit")
        var finished = false
        let finish = { if !finished { finished = true; done() } }
        closeForQuit = finish
        cam.requestCloseSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }
    }

    func resetLibraryState() {
        sessionWatchdog?.cancel()
        settleWork?.cancel()
        catalogTimer?.invalidate()
        items = []
        itemIndex = [:]
        selection = []
        catalogComplete = false
        catalogPercent = 0
        accessRestricted = false
        lastSummary = nil
        clearPreviewCache()
        recomputeViews()
    }

    func deviceWentAway(_ device: ICDevice) {
        if let review = deleteReview, review.camera === device {
            deleteReview = nil
            replaceReviewNote(with: "The phone was disconnected, so nothing was deleted.")
        }
        if device === importingCamera {
            failActiveDownloads("Device disconnected")
        }
        cameras.removeAll { $0 === device }
        if selectedCamera === device { selectedCamera = cameras.first }
    }

    func lastCountKey(_ device: ICDevice) -> String {
        "lastCatalogCount.\(device.name ?? "device")"
    }

    /// Waits until the device's file count stops changing (checked every second, up to 15 s).
    func settleCatalog(_ device: ICCameraDevice, lastCount: Int, stableTicks: Int, ticks: Int) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, device === self.selectedCamera else { return }
            let now = (device.mediaFiles ?? []).count
            if ticks >= 15 || (now == lastCount && stableTicks >= 1) {
                self.finishCatalog(device)
            } else {
                self.deviceStatus = "Reading library… \(now) files"
                self.settleCatalog(device, lastCount: now,
                                   stableTicks: now == lastCount ? stableTicks + 1 : 0, ticks: ticks + 1)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func finishCatalog(_ device: ICCameraDevice) {
        let count = (device.mediaFiles ?? []).count
        DeviceLog.write("Library ready: \(count) files")
        defaults.set(count, forKey: lastCountKey(device))
        sessionWatchdog?.cancel()
        catalogComplete = true
        catalogPercent = 100
        catalogTimer?.invalidate()
        itemIndex = [:]
        setItems(makeItems(device.mediaFiles ?? []))
        deviceStatus = "\(items.count) items on \(device.name ?? "device")"

        let byKey = Dictionary(grouping: items, by: \.matchKey)
        if let keys = reselectKeys {
            selection = Set(keys.compactMap { byKey[$0]?.count == 1 ? byKey[$0]?.first?.id : nil })
            reselectKeys = nil
        }
    }
}

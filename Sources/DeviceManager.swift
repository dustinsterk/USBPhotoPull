import AppKit
import ImageCaptureCore

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case screenshots = "Screenshots"
    case other = "Other images"
    var id: String { rawValue }

    func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all: return true
        case .photos: return item.kind == .photo
        case .videos: return item.kind == .video
        case .screenshots: return item.kind == .screenshot
        case .other: return item.kind == .otherImage
        }
    }
}

enum RenameMode: String, CaseIterable, Identifiable {
    case original
    case dateTimeOriginal
    case dateTime
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Keep original name — IMG_1234.HEIC"
        case .dateTimeOriginal: return "Date + name — 2026-11-03_143012_IMG_1234.HEIC"
        case .dateTime: return "Date only — 2026-11-03_143012.HEIC"
        }
    }

    var shortLabel: String {
        switch self {
        case .original: return "Original names"
        case .dateTimeOriginal: return "Date + name"
        case .dateTime: return "Date names"
        }
    }
}

struct DayGroup: Identifiable {
    let id: String
    let day: Date?
    var items: [PhotoItem]
}

struct ImportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Finds USB devices (iPhone/iPad/cameras via PTP), lists their media, and imports it.
final class DeviceManager: NSObject, ObservableObject {
    static let shared = DeviceManager()

    // MARK: Devices
    @Published var cameras: [ICCameraDevice] = []
    @Published var selectedCamera: ICCameraDevice? {
        didSet { if oldValue !== selectedCamera { switchCamera(from: oldValue) } }
    }
    @Published var deviceStatus = DeviceManager.idleStatus
    @Published var catalogPercent = 0
    @Published var catalogComplete = false
    @Published var accessRestricted = false

    // MARK: Library (cached views are rebuilt by recomputeViews())
    @Published var items: [PhotoItem] = []
    @Published var visibleItems: [PhotoItem] = []
    @Published var visibleGroups: [DayGroup] = []
    @Published var newItems: [PhotoItem] = []
    @Published var filteredCount = 0
    @Published var kindCounts: [MediaFilter: Int] = [:]
    var visibleIndex: [ObjectIdentifier: Int] = [:]
    @Published var selection: Set<ObjectIdentifier> = []

    // MARK: Filters (per session)
    @Published var mediaFilter: MediaFilter = .all { didSet { filtersChanged() } }
    @Published var dateFilterEnabled = false { didSet { filtersChanged() } }
    @Published var dateFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() {
        didSet { if dateFilterEnabled { filtersChanged() } }
    }
    @Published var dateTo: Date = Date() {
        didSet { if dateFilterEnabled { filtersChanged() } }
    }

    // MARK: Import progress
    @Published var isImporting = false
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var currentFile: String?
    @Published var lastSummary: String?
    var cancelRequested = false

    // MARK: Settings (persisted)
    @Published var destination: URL {
        didSet { defaults.set(destination.path, forKey: Keys.destination); refreshImportedState() }
    }
    @Published var useDateSubfolders: Bool {
        didSet { defaults.set(useDateSubfolders, forKey: Keys.subfolders); refreshImportedState() }
    }
    @Published var renameMode: RenameMode {
        didSet { defaults.set(renameMode.rawValue, forKey: Keys.rename); refreshImportedState() }
    }
    @Published var skipExisting: Bool {
        didSet { defaults.set(skipExisting, forKey: Keys.skip) }
    }
    @Published var hideImported: Bool {
        didSet { defaults.set(hideImported, forKey: Keys.hide); recomputeViews() }
    }
    @Published var deleteAfterImport: Bool {
        didSet { defaults.set(deleteAfterImport, forKey: Keys.delete) }
    }
    /// How many downloads to keep queued on the device at once (1–4).
    @Published var parallelDownloads: Int {
        didSet { defaults.set(parallelDownloads, forKey: Keys.parallel) }
    }
    /// Put screenshots under <destination>/Screenshots instead of with the photos.
    @Published var screenshotsFolder: Bool {
        didSet { defaults.set(screenshotsFolder, forKey: Keys.screenshots); refreshImportedState() }
    }
    @Published var sortNewestFirst: Bool {
        didSet { defaults.set(sortNewestFirst, forKey: Keys.sort); resort() }
    }
    @Published var thumbnailSize: Double {
        didSet { defaults.set(thumbnailSize, forKey: Keys.thumb) }
    }
    @Published var notifyWhenDone: Bool {
        didSet {
            defaults.set(notifyWhenDone, forKey: Keys.notify)
            if notifyWhenDone { Notifier.requestPermission() }
        }
    }
    /// Show the review sheet (exact list of what will be deleted) before deleting from the device.
    @Published var askBeforeDeleting: Bool {
        didSet { defaults.set(askBeforeDeleting, forKey: Keys.askDelete) }
    }
    /// The delete waiting for review, if any (drives the review sheet).
    @Published var deleteReview: DeleteReview?
    /// Skip the short .MOV half of iPhone Live Photos (keeps the still image only).
    @Published var skipLivePhotoVideos: Bool {
        didSet { defaults.set(skipLivePhotoVideos, forKey: Keys.skipLive); filtersChanged(); refreshImportedState() }
    }

    let defaults = UserDefaults.standard

    // MARK: Session state (see DeviceManager+Session)
    var browser = ICDeviceBrowser()
    var started = false
    var itemIndex: [ObjectIdentifier: PhotoItem] = [:]
    var catalogTimer: Timer?
    var sessionWatchdog: DispatchWorkItem?
    var rediscoveryWatchdog: DispatchWorkItem?
    var settleWork: DispatchWorkItem?
    var openAttempts = 0
    var browserRestarted = false
    /// The first catalog after the device appears is often incomplete; reconnect once.
    var warmupPending = false
    var emptyRetries = 0
    var lowCountRetries = 0
    var lastLoggedPercent = -1
    var reselectKeys: Set<String>?
    var closeForQuit: (() -> Void)?

    // MARK: Import state (see DeviceManager+Import)
    var importingCamera: ICCameraDevice?
    var activeDownloads: [UUID: PendingDownload] = [:]
    var tempFolders = Set<URL>()
    var log: ImportLog?
    var logDevice = ""

    // MARK: Delete state (see DeviceManager+Delete)
    var pendingDelete: (destination: URL, device: String, camera: ICCameraDevice, names: Set<String>)?
    /// (reason, file name) pairs the device reported while deleting.
    var deleteFailures: [(String, String)] = []

    // MARK: Preview cache (see DeviceManager+Preview)
    var previewCache: [ObjectIdentifier: URL] = [:]
    var previewOrder: [ObjectIdentifier] = []

    static let idleStatus = "Connect an iPhone or iPad with a USB cable, unlock it, and tap “Trust”."
    static let sidecarExtensions: Set<String> = ["aae", "xmp", "thm"]
    static let movieExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let tempFolderName = ".usbphotopull-partial"

    enum Keys {
        static let destination = "destinationPath"
        static let subfolders = "useDateSubfolders"
        static let rename = "renameMode"
        static let skip = "skipExisting"
        static let hide = "hideImported"
        static let delete = "deleteAfterImport"
        static let skipLive = "skipLivePhotoVideos"
        static let parallel = "parallelDownloads"
        static let askDelete = "askBeforeDeleting"
        static let sort = "sortNewestFirst"
        static let screenshots = "screenshotsFolder"
        static let thumb = "thumbnailSize"
        static let notify = "notifyWhenDone"
    }

    override init() {
        let d = UserDefaults.standard
        if let path = d.string(forKey: Keys.destination) {
            destination = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            destination = pictures.appendingPathComponent("USBPhotoPull Imports", isDirectory: true)
        }
        useDateSubfolders = d.object(forKey: Keys.subfolders) as? Bool ?? true
        renameMode = RenameMode(rawValue: d.string(forKey: Keys.rename) ?? "") ?? .original
        skipExisting = d.object(forKey: Keys.skip) as? Bool ?? true
        hideImported = d.object(forKey: Keys.hide) as? Bool ?? false
        deleteAfterImport = d.object(forKey: Keys.delete) as? Bool ?? false
        skipLivePhotoVideos = d.object(forKey: Keys.skipLive) as? Bool ?? true
        parallelDownloads = min(max(d.object(forKey: Keys.parallel) as? Int ?? 2, 1), 4)
        askBeforeDeleting = d.object(forKey: Keys.askDelete) as? Bool ?? true
        sortNewestFirst = d.object(forKey: Keys.sort) as? Bool ?? true
        screenshotsFolder = d.object(forKey: Keys.screenshots) as? Bool ?? false
        thumbnailSize = min(max(d.object(forKey: Keys.thumb) as? Double ?? 140, 90), 280)
        notifyWhenDone = d.object(forKey: Keys.notify) as? Bool ?? true
        super.init()
    }
}

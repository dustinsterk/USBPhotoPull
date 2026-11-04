import SwiftUI

/// USBPhotoPull ▸ Settings… (⌘,)
struct SettingsView: View {
    @EnvironmentObject var manager: DeviceManager
    @State private var cacheSize = "…"

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Folder") {
                    HStack {
                        Text(manager.destination.path)
                            .lineLimit(1).truncationMode(.head)
                            .help(manager.destination.path)
                        Button("Choose…") { manager.chooseDestination() }
                    }
                }
            }

            Section {
                Toggle("Sort into date folders (YYYY/YYYY-MM-DD)", isOn: $manager.useDateSubfolders)
                Toggle("Put screenshots in a separate “Screenshots” folder", isOn: $manager.screenshotsFolder)
                Picker("File names", selection: $manager.renameMode) {
                    ForEach(RenameMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Organizing")
            } footer: {
                Text("Folders and date-based names use the local time where each photo was taken, read from the file during import, so travel photos land on the right day.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Import") {
                Toggle("Skip files already in the destination", isOn: $manager.skipExisting)
                Toggle("Skip Live Photo videos (keep the still only)", isOn: $manager.skipLivePhotoVideos)
                Stepper("Parallel downloads: \(manager.parallelDownloads)",
                        value: $manager.parallelDownloads, in: 1...4)
                Toggle("Delete from device after import", isOn: $manager.deleteAfterImport)
                if manager.deleteAfterImport {
                    Toggle("Review the list before deleting", isOn: $manager.askBeforeDeleting)
                        .padding(.leading, 20)
                    Text(manager.askBeforeDeleting
                         ? "After each import you see exactly what will be deleted, and can untick days or items. Nothing is deleted until you confirm."
                         : "Verified files are deleted automatically after each import (you confirm once before it starts). Deleting over USB is permanent.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
            .disabled(manager.isImporting)

            Section("Browsing") {
                Picker("Sort", selection: $manager.sortNewestFirst) {
                    Text("Newest first").tag(true)
                    Text("Oldest first").tag(false)
                }
                .pickerStyle(.segmented)
                LabeledContent("Thumbnail size") {
                    Slider(value: $manager.thumbnailSize, in: 90...280)
                        .frame(width: 220)
                }
            }

            Section("Thumbnails") {
                LabeledContent("Saved thumbnails") {
                    HStack {
                        Text(cacheSize).foregroundStyle(.secondary)
                        Button("Clear") {
                            ThumbnailCache.clear()
                            cacheSize = "0 KB"
                        }
                    }
                }
            }
            .onAppear {
                cacheSize = ByteCountFormatter.string(fromByteCount: ThumbnailCache.diskSize(), countStyle: .file)
            }

            Section("Notifications") {
                Toggle("Notify me when an import finishes (when USBPhotoPull is in the background)",
                       isOn: $manager.notifyWhenDone)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }
}

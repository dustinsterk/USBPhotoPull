import SwiftUI
import AppKit

@main
struct USBPhotoPullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DeviceManager.shared

    var body: some Scene {
        WindowGroup("USBPhotoPull") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 860, minHeight: 540)
                .onAppear { manager.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .help) {
                Button("Open Device Log") { DeviceLog.open() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Close the device session cleanly (up to 2 s) before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DeviceManager.shared.prepareToQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DeviceManager.shared.shutdown()
    }
}

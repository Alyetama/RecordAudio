import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved Dock-icon preference as early as possible.
        Appearance.applyDockPolicyFromDefaults()
    }

    // Keep running (in the menu bar) when the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // If a recording is in progress, finalize the file before quitting so it
    // isn't left half-written and unplayable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecorderModel.shared?.isRecording == true else { return .terminateNow }
        Task { @MainActor in
            await RecorderModel.shared?.finishForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RecordAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel()
    // Menu-bar visibility lives in AppStorage, NOT in the observed model, so the
    // MenuBarExtra binding can never trigger a recording-UI re-render loop.
    @AppStorage(Appearance.showMenuBarKey) private var showMenuBarIcon = true

    var body: some Scene {
        Window("RecordAudio", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 380, height: 460)

        // Menu-bar icon is optional — toggled from Settings.
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuView(model: model)
        } label: {
            Image(systemName: model.isRecording ? "largecircle.fill.circle" : "waveform")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

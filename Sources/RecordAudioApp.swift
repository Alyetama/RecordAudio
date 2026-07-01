import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved Dock-icon preference as early as possible.
        let showDock = (UserDefaults.standard.object(forKey: "showDockIcon") as? Bool) ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    // Keep running (in the menu bar) when the main window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct RecordAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel()

    var body: some Scene {
        Window("RecordAudio", id: "main") {
            MainView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 380, height: 460)

        // Menu-bar icon is optional — toggled from Settings.
        MenuBarExtra(isInserted: $model.showMenuBarIcon) {
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

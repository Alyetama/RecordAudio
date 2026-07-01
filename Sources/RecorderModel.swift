import Foundation
import SwiftUI
import AppKit

/// Audio quality presets. Lower bitrate = smaller file. AAC-LC at 128 kbps is a
/// good "small but not bad" default (~1 MB per minute, stereo).
enum Quality: Int, CaseIterable, Identifiable {
    case small    = 96_000
    case balanced = 128_000
    case high     = 192_000

    var id: Int { rawValue }
    var bitrate: Int { rawValue }

    var label: String {
        switch self {
        case .small:    return "Small"
        case .balanced: return "Balanced"
        case .high:     return "High"
        }
    }

    /// Rough size estimate, stereo.
    var perMinute: String {
        switch self {
        case .small:    return "≈0.7 MB/min"
        case .balanced: return "≈1.0 MB/min"
        case .high:     return "≈1.4 MB/min"
        }
    }
}

@MainActor
final class RecorderModel: ObservableObject {

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastFileURL: URL?
    @Published var statusMessage: String?
    @Published var permissionNeeded = false

    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "bitrate") }
    }
    @Published var folderURL: URL {
        didSet { UserDefaults.standard.set(folderURL.path, forKey: "folder") }
    }
    @Published var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            if !showMenuBarIcon && !showDockIcon { showDockIcon = true }  // stay reachable
        }
    }
    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            applyActivationPolicy()
            if !showDockIcon && !showMenuBarIcon { showMenuBarIcon = true }  // stay reachable
        }
    }

    private let recorder = SystemAudioRecorder()
    private var timer: Timer?
    private var startDate: Date?

    init() {
        let defaults = UserDefaults.standard
        let savedBitrate = defaults.integer(forKey: "bitrate")
        quality = Quality(rawValue: savedBitrate) ?? .balanced

        showMenuBarIcon = (defaults.object(forKey: "showMenuBarIcon") as? Bool) ?? true
        showDockIcon = (defaults.object(forKey: "showDockIcon") as? Bool) ?? true

        if let saved = defaults.string(forKey: "folder") {
            folderURL = URL(fileURLWithPath: saved)
        } else {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            folderURL = music.appendingPathComponent("RecordAudio", isDirectory: true)
        }

        recorder.onError = { [weak self] message in
            Task { @MainActor in self?.handleStreamError(message) }
        }
    }

    var elapsedString: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Control

    func toggle() {
        if isRecording {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    private func start() async {
        statusMessage = nil
        permissionNeeded = false

        do {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Can't create the recordings folder."
            return
        }

        let url = folderURL.appendingPathComponent(makeFileName())
        do {
            try await recorder.start(to: url, bitrate: quality.bitrate)
            isRecording = true
            startDate = Date()
            elapsed = 0
            startTimer()
        } catch {
            handleStreamError(error.localizedDescription)
        }
    }

    private func stop() async {
        stopTimer()
        let url = await recorder.stop()
        isRecording = false
        if let url, FileManager.default.fileExists(atPath: url.path) {
            lastFileURL = url
        }
    }

    // MARK: - Errors / permission

    private func handleStreamError(_ message: String) {
        stopTimer()
        isRecording = false

        // ScreenCaptureKit reports a "declined" / "not authorized" style error
        // when Screen Recording permission is missing.
        let lower = message.lowercased()
        if lower.contains("declined") || lower.contains("permission")
            || lower.contains("authorized") || lower.contains("-3801") {
            permissionNeeded = true
            statusMessage = "Screen Recording permission is required to capture system audio."
        } else {
            statusMessage = message
        }
    }

    // MARK: - Presentation

    /// Show or hide the Dock icon (regular vs. accessory app).
    func applyActivationPolicy() {
        NSApp?.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    /// Open the standard Settings window (works across macOS 13–26).
    func openAppSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Files

    func revealLastFile() {
        guard let url = lastFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFolder() {
        try? FileManager.default.createDirectory(
            at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = folderURL
        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
        }
    }

    private func makeFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "System Audio \(f.string(from: Date())).m4a"
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
    }
}

import Foundation
import SwiftUI
import AppKit
import ScreenCaptureKit

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

    /// Weak handle so the app delegate can finalize an in-progress recording at
    /// quit time. Set once, on the main actor, from `init`.
    nonisolated(unsafe) static private(set) weak var shared: RecorderModel?

    private let recorder = SystemAudioRecorder()
    private var timer: Timer?
    private var startDate: Date?
    /// True while a start/stop is in flight — blocks re-entrant toggles.
    private var isTransitioning = false

    init() {
        let defaults = UserDefaults.standard
        let savedBitrate = defaults.integer(forKey: "bitrate")
        quality = Quality(rawValue: savedBitrate) ?? .balanced

        if let saved = defaults.string(forKey: "folder") {
            folderURL = URL(fileURLWithPath: saved)
        } else {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            folderURL = music.appendingPathComponent("RecordAudio", isDirectory: true)
        }

        recorder.onError = { [weak self] error in
            Task { @MainActor in await self?.streamStoppedUnexpectedly(error) }
        }

        Self.shared = self
    }

    var elapsedString: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Control

    func toggle() {
        // Ignore repeat presses while a start/stop is still resolving, otherwise
        // a double-click could kick off two overlapping captures.
        guard !isTransitioning else { return }
        isTransitioning = true
        Task {
            if isRecording { await stop() } else { await start() }
            isTransitioning = false
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
            isRecording = false          // recorder already rolled back its state
            report(error)
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

    /// Finalize an in-progress recording before the app quits, so the file isn't
    /// left half-written (unplayable).
    func finishForQuit() async {
        guard isRecording else { return }
        stopTimer()
        let url = await recorder.stop()
        isRecording = false
        if let url, FileManager.default.fileExists(atPath: url.path) {
            lastFileURL = url
        }
    }

    // MARK: - Errors / permission

    /// The capture stream died on its own (e.g. permission revoked mid-recording,
    /// display disconnected). Salvage whatever was written, then surface the error.
    private func streamStoppedUnexpectedly(_ error: Error) async {
        guard isRecording else { return }   // ignore stray callbacks after a clean stop
        stopTimer()
        let url = await recorder.stop()
        isRecording = false
        if let url, FileManager.default.fileExists(atPath: url.path) {
            lastFileURL = url
        }
        report(error)
    }

    private func report(_ error: Error) {
        // Detect the missing-Screen-Recording-permission case by error *code*
        // (locale-independent) rather than matching English error text.
        let ns = error as NSError
        let declined = (ns.domain == SCStreamError.errorDomain
                        && ns.code == SCStreamError.Code.userDeclined.rawValue)
                    || ns.code == -3801
        if declined {
            permissionNeeded = true
            statusMessage = "Screen Recording permission is required to capture system audio."
        } else {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Presentation

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
        f.locale = Locale(identifier: "en_US_POSIX")   // stable filenames in any locale
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

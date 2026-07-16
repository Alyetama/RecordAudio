import Foundation
import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

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
    @Published var lastDuration: Double?
    @Published var statusMessage: String?
    @Published var permissionNeeded = false

    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "bitrate") }
    }
    @Published var folderURL: URL {
        didSet { UserDefaults.standard.set(folderURL.path, forKey: "folder") }
    }

    /// Which audio to capture — all system audio, or one specific app.
    @Published var source: AudioSource {
        didSet {
            switch source {
            case .system:
                UserDefaults.standard.removeObject(forKey: "sourceBundleID")
            case .app(let bid):
                UserDefaults.standard.set(bid, forKey: "sourceBundleID")
            }
        }
    }
    /// Last-known display name for the selected app (so the picker can label it
    /// even when the app isn't currently running).
    @Published var sourceName: String? {
        didSet { UserDefaults.standard.set(sourceName, forKey: "sourceName") }
    }
    /// Running apps that own on-screen windows — candidates for a per-app source.
    @Published var availableApps: [AudioApp] = []

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

        if let bid = defaults.string(forKey: "sourceBundleID"), !bid.isEmpty {
            source = .app(bundleID: bid)
            sourceName = defaults.string(forKey: "sourceName")
        } else {
            source = .system
            sourceName = nil
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
            try await recorder.start(to: url, bitrate: quality.bitrate, source: source)
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
        setLastFile(url)
    }

    /// Finalize an in-progress recording before the app quits, so the file isn't
    /// left half-written (unplayable).
    func finishForQuit() async {
        guard isRecording else { return }
        stopTimer()
        let url = await recorder.stop()
        isRecording = false
        setLastFile(url)
    }

    private func setLastFile(_ url: URL?) {
        lastDuration = nil
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        lastFileURL = url
        Task {
            let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds
            if lastFileURL == url { lastDuration = seconds }
        }
    }

    // MARK: - Trim editor

    /// Open the Trim editor for the most recent recording (used by the "Trim…" button).
    func trimLastRecording() {
        guard let url = lastFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        presentTrimEditor(for: url)
    }

    /// Transcribe the most recent recording with Whisper (progress shown inline).
    func transcribeLastRecording() {
        guard let url = lastFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        TranscriptionManager.shared.transcribe(url)
    }

    // Per-file actions (used by the History window).
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func trim(_ url: URL) { presentTrimEditor(for: url) }
    func transcribe(_ url: URL) { TranscriptionManager.shared.transcribe(url) }

    /// Open the paginated History window listing every recording in the folder.
    func showHistory() {
        HistoryPresenter.shared.present(folder: folderURL, recorder: self)
    }

    private func presentTrimEditor(for url: URL) {
        TrimWindowPresenter.shared.present(url: url) { [weak self] in
            // The file was replaced in place (same path); nudge the UI to refresh.
            self?.lastFileURL = nil
            self?.lastFileURL = url
        }
    }

    // MARK: - Audio source

    /// Set the capture source, remembering the app's display name for the picker.
    func selectSource(_ newValue: AudioSource) {
        source = newValue
        switch newValue {
        case .system:
            sourceName = nil
        case .app(let bid):
            sourceName = availableApps.first(where: { $0.bundleID == bid })?.name ?? sourceName
        }
    }

    /// Refresh the list of pickable apps. Requires Screen Recording permission —
    /// before it's granted this quietly stays empty.
    ///
    /// Built from `content.applications` — the exact same source `start()` uses
    /// to resolve a chosen app — rather than deriving from on-screen window
    /// geometry. Deriving from windows missed apps like Vesktop whose window
    /// wasn't flagged "on screen" (minimized, on another Space, background tray
    /// mode, …) even though ScreenCaptureKit can still capture their audio.
    func refreshApps() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return }

        // Only list "real" apps a user would recognize as running — i.e. those
        // with a regular Dock presence — to filter out background helpers/agents
        // that ScreenCaptureKit otherwise reports.
        let regularBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )

        let myBundleID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var apps: [AudioApp] = []
        for app in content.applications {
            let bid = app.bundleIdentifier
            guard !bid.isEmpty, bid != myBundleID, regularBundleIDs.contains(bid),
                  !seen.contains(bid) else { continue }
            seen.insert(bid)
            let name = app.applicationName.isEmpty ? bid : app.applicationName
            apps.append(AudioApp(bundleID: bid, name: name))
        }
        availableApps = apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // Keep the remembered name current if the selected app is running.
        if case .app(let bid) = source,
           let match = availableApps.first(where: { $0.bundleID == bid }) {
            sourceName = match.name
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
        setLastFile(url)
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
    ///
    /// Sending `showSettingsWindow:`/`showPreferencesWindow:` with a nil target
    /// walks the responder chain, which doesn't reliably reach the private
    /// object SwiftUI wires the Settings scene's action to — from a plain
    /// button that silently does nothing. The app's own "Settings…" menu item
    /// *does* work, so reuse its exact target/action instead of guessing.
    func openAppSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let item = settingsMenuItem(), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        // Fallback for the rare case the menu item can't be found.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func settingsMenuItem() -> NSMenuItem? {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return nil }
        return appMenu.items.first {
            $0.title.localizedCaseInsensitiveContains("Settings")
            || $0.title.localizedCaseInsensitiveContains("Preferences")
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

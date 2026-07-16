import AppKit
import SwiftUI
import AVFoundation

/// A recording on disk, for the History list.
struct Recording: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int
    var duration: Double = 0
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Formats seconds as m:ss (or "—" when unknown).
func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Like formatDuration but always shows a clock (0:00), for the transport.
func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

@MainActor
final class HistoryModel: ObservableObject {
    let folder: URL
    weak var recorder: RecorderModel?

    @Published var recordings: [Recording] = []
    @Published var page = 0

    // In-app playback of the selected recording.
    @Published var playingURL: URL?
    @Published var isPlaying = false
    @Published var playhead: Double = 0
    @Published var playDuration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    let pageSize = 8

    init(folder: URL, recorder: RecorderModel?) {
        self.folder = folder
        self.recorder = recorder
    }

    var pageCount: Int { max(1, Int(ceil(Double(recordings.count) / Double(pageSize)))) }

    var pageItems: ArraySlice<Recording> {
        let start = page * pageSize
        guard start < recordings.count else { return [][...] }
        return recordings[start..<min(start + pageSize, recordings.count)]
    }

    func load() async {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys)) ?? []
        var recs = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .map { url -> Recording in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return Recording(url: url,
                                 modified: v?.contentModificationDate ?? .distantPast,
                                 size: v?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
        recordings = recs                       // show the list immediately
        if page >= pageCount { page = pageCount - 1 }

        // Then fill in durations and republish.
        for i in recs.indices {
            recs[i].duration = (try? await AVURLAsset(url: recs[i].url).load(.duration))?.seconds ?? 0
        }
        recordings = recs
    }

    // MARK: - Playback

    /// Play a row (or toggle it if it's already the loaded one).
    func play(_ rec: Recording) {
        if playingURL == rec.url {
            togglePlay()
            return
        }
        stopTimer()
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: rec.url) else { return }
        player = p
        p.prepareToPlay()
        playingURL = rec.url
        playDuration = p.duration
        playhead = 0
        p.play()
        isPlaying = true
        startTimer()
    }

    func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause(); isPlaying = false; stopTimer()
        } else {
            if playhead >= playDuration - 0.03 { playhead = 0; p.currentTime = 0 }
            p.play(); isPlaying = true; startTimer()
        }
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        let t = min(max(0, time), playDuration)
        p.currentTime = t
        playhead = t
    }

    func stopPlayback() {
        player?.stop(); player = nil
        stopTimer()
        isPlaying = false
        playingURL = nil
        playhead = 0
        playDuration = 0
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let p = player else { return }
        if p.isPlaying {
            playhead = p.currentTime
        } else {
            isPlaying = false
            stopTimer()
            if playhead >= playDuration - 0.1 { playhead = playDuration }
        }
    }

    private func stopTimer() {
        timer?.invalidate(); timer = nil
    }
}

/// AppKit-hosted so it works in menu-bar-only mode too.
@MainActor
final class HistoryPresenter: NSObject, NSWindowDelegate {
    static let shared = HistoryPresenter()
    private var window: NSWindow?

    func present(folder: URL, recorder: RecorderModel) {
        if let window {                     // one history window; just refront it
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.contentViewController = NSHostingController(
            rootView: HistoryView(model: HistoryModel(folder: folder, recorder: recorder)))
        win.title = "Recordings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct HistoryView: View {
    @StateObject var model: HistoryModel
    // Observed so finishing a transcription re-renders the rows (the "transcribed"
    // badge below reads the file system, so it needs a redraw to pick up the change).
    @ObservedObject private var transcriptions = TranscriptionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recordings").font(.headline)
                Text("\(model.recordings.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }

            if model.recordings.isEmpty {
                Text("No recordings yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(model.pageItems)) { rec in
                            row(rec)
                        }
                    }
                }
                pager
            }

            if model.playingURL != nil {
                transport
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { Task { await model.load() } }
        .onDisappear { model.stopPlayback() }
    }

    private func row(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(rec.name).lineLimit(1).truncationMode(.middle)
                        if Transcriber.hasTranscript(for: rec.url) {
                            Button {
                                NSWorkspace.shared.open(Transcriber.transcriptURL(for: rec.url))
                            } label: {
                                Image(systemName: "captions.bubble.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcript (.srt)")
                        }
                    }
                    Text("\(formatDuration(rec.duration)) · \(rec.modified.formatted(date: .abbreviated, time: .shortened)) · \(sizeString(rec.size))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.play(rec)
                } label: {
                    Image(systemName: (model.playingURL == rec.url && model.isPlaying) ? "pause.fill" : "play.fill")
                }
                .controlSize(.small)
                .help("Play")
                Button("Show") { model.recorder?.reveal(rec.url) }.controlSize(.small)
                Button("Trim…") { model.recorder?.trim(rec.url) }.controlSize(.small)
                Button("Transcribe") { model.recorder?.transcribe(rec.url) }.controlSize(.small)
            }
            TranscriptionInlineView(url: rec.url)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transport: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 10) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.playingURL?.lastPathComponent ?? "")
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(formatClock(model.playhead)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        Slider(value: Binding(get: { model.playhead },
                                              set: { model.seek(to: $0) }),
                               in: 0...max(model.playDuration, 0.01))
                        Text(formatClock(model.playDuration)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Button { model.stopPlayback() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Close player")
            }
        }
    }

    private var pager: some View {
        HStack {
            Button { if model.page > 0 { model.page -= 1 } } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(model.page == 0)
            Spacer()
            Text("Page \(model.page + 1) of \(model.pageCount)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { if model.page < model.pageCount - 1 { model.page += 1 } } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(model.page >= model.pageCount - 1)
        }
        .controlSize(.small)
    }

    private func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

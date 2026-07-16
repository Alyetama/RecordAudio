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

@MainActor
final class HistoryModel: ObservableObject {
    let folder: URL
    weak var recorder: RecorderModel?

    @Published var recordings: [Recording] = []
    @Published var page = 0

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
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { Task { await model.load() } }
    }

    private func row(_ rec: Recording) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.name).lineLimit(1).truncationMode(.middle)
                Text("\(formatDuration(rec.duration)) · \(rec.modified.formatted(date: .abbreviated, time: .shortened)) · \(sizeString(rec.size))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show") { model.recorder?.reveal(rec.url) }.controlSize(.small)
            Button("Trim…") { model.recorder?.trim(rec.url) }.controlSize(.small)
            Button("Transcribe") { model.recorder?.transcribe(rec.url) }.controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

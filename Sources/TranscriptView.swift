import AppKit
import SwiftUI

/// Presents the transcript window (AppKit, like the Trim editor) so it works in
/// menu-bar-only mode too.
@MainActor
final class TranscriptPresenter: NSObject, NSWindowDelegate {
    static let shared = TranscriptPresenter()
    private var windows = Set<NSWindow>()

    func present(url: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: TranscriptView(url: url))
        window.title = "Transcript"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows.insert(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
    }
}

struct TranscriptView: View {
    let url: URL

    private enum Phase: Equatable { case working, done(String), failed(String) }
    @State private var phase: Phase = .working

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript").font(.headline)
            Text(url.lastPathComponent)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            switch phase {
            case .working:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Transcribing with Whisper (tiny)…")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("First run downloads the model (~75 MB).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .done(let text):
                ScrollView {
                    Text(text.isEmpty ? "(no speech detected)" : text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Reveal .txt") {
                        let txt = url.deletingPathExtension().appendingPathExtension("txt")
                        NSWorkspace.shared.activateFileViewerSelecting([txt])
                    }
                    Spacer()
                }

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .task {
            do { phase = .done(try await Transcriber.transcribe(url)) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }
}

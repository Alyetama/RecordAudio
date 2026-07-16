import SwiftUI
import AppKit

/// Runs transcriptions and publishes per-recording progress so the UI can show
/// it *inline* (in the History window, the main window, the menu-bar panel)
/// instead of opening a separate window.
@MainActor
final class TranscriptionManager: ObservableObject {
    static let shared = TranscriptionManager()

    enum State: Equatable {
        case downloading(Double)
        case preparing
        case transcribing(Double)
        case done(String)
        case failed(String)

        /// Still working (as opposed to finished or errored).
        var isActive: Bool {
            switch self {
            case .done, .failed: return false
            default:             return true
            }
        }
    }

    @Published private(set) var states: [URL: State] = [:]

    func state(for url: URL) -> State? { states[url] }

    /// Start (or restart) transcribing `url`. No-op if it's already running.
    func transcribe(_ url: URL) {
        if let s = states[url], s.isActive { return }
        states[url] = Transcriber.isModelPresent ? .preparing : .downloading(0)
        Task {
            do {
                let text = try await Transcriber.transcribe(url) { progress in
                    Task { @MainActor in
                        switch progress {
                        case .downloadingModel(let p): self.states[url] = .downloading(p)
                        case .preparingAudio:          self.states[url] = .preparing
                        case .transcribing(let p):     self.states[url] = .transcribing(p)
                        }
                    }
                }
                states[url] = .done(text)
            } catch {
                states[url] = .failed(error.localizedDescription)
            }
        }
    }

    /// Clear an inline panel (finished or errored).
    func dismiss(_ url: URL) { states[url] = nil }
}

/// Inline progress/result panel for one recording. Renders nothing until a
/// transcription is started for `url`. `compact` trims it for the menu-bar panel.
struct TranscriptionInlineView: View {
    let url: URL
    var compact = false
    @ObservedObject private var manager = TranscriptionManager.shared

    var body: some View {
        if let state = manager.state(for: url) {
            switch state {
            case .downloading(let p):
                progress("Downloading model…", p)
            case .preparing:
                progress("Preparing audio…", nil)
            case .transcribing(let p):
                progress("Transcribing…", p > 0 ? p : nil)
            case .done(let text):
                done(text)
            case .failed(let message):
                failed(message)
            }
        }
    }

    // MARK: - Sub-states

    private func progress(_ title: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            if let value {
                ProgressView(value: value).controlSize(.small)
                    .frame(maxWidth: compact ? 90 : 160)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func failed(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(message).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { manager.dismiss(url) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func done(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Transcript ready").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([Transcriber.transcriptURL(for: url)])
                }
                Button { manager.dismiss(url) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)

            if !compact {
                ScrollView {
                    Text(text.isEmpty ? "(no speech detected)" : text)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 2)
    }
}

import SwiftUI
import AppKit

/// The compact panel that drops down from the menu-bar icon.
struct MenuView: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("System Audio Recorder").font(.headline)
            }

            RecordButton(model: model)

            if let last = model.lastFileURL, !model.isRecording {
                lastFileRow(last)
            }

            if model.permissionNeeded {
                PermissionBanner(model: model)
            } else if let msg = model.statusMessage {
                Text(msg)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    Label("Open Window", systemImage: "macwindow")
                }
                Spacer()
                Button {
                    model.openAppSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
            }
            .controlSize(.small)

            Divider()

            HStack {
                Text("\(model.quality.label) · \(model.quality.bitrate / 1000) kbps")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func lastFileRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Show") { model.revealLastFile() }.controlSize(.small)
        }
    }
}

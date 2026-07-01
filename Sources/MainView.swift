import SwiftUI
import AppKit

/// The regular app window shown when RecordAudio runs with a Dock icon.
struct MainView: View {
    @ObservedObject var model: RecorderModel

    private let brand = LinearGradient(
        colors: [Color(red: 0.49, green: 0.20, blue: 0.96),
                 Color(red: 1.00, green: 0.24, blue: 0.42)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 16) {
            header
            RecordButton(model: model, large: true)

            if model.isRecording {
                Label("Recording system audio…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let last = model.lastFileURL {
                lastFileRow(last)
            }

            if model.permissionNeeded {
                PermissionBanner(model: model)
            } else if let msg = model.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            bottomBar
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 440)
        .onAppear { model.applyActivationPolicy() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(brand)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("RecordAudio").font(.title2.bold())
            Text("Records what your Mac plays — not the mic.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func lastFileRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Show") { model.revealLastFile() }.controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bottomBar: some View {
        HStack {
            Button { model.openFolder() } label: {
                Label(model.folderURL.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(.link)

            Spacer()

            Button { model.openAppSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .font(.callout)
    }
}

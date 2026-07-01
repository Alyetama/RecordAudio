import SwiftUI

/// The Settings window (⌘,). Holds recording quality, save location, and how the
/// app presents itself (menu bar and/or Dock).
struct SettingsView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(Quality.allCases) { q in
                        Text("\(q.label) — \(q.bitrate / 1000) kbps").tag(q)
                    }
                }
                .disabled(model.isRecording)
                LabeledContent("Estimated size", value: model.quality.perMinute)
            }

            Section("Save location") {
                LabeledContent("Folder") {
                    Text(model.folderURL.path)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Change…") { model.chooseFolder() }
                        .disabled(model.isRecording)
                    Button("Open in Finder") { model.openFolder() }
                }
            }

            Section("Appearance") {
                Toggle("Show menu bar icon", isOn: $model.showMenuBarIcon)
                Toggle("Show Dock icon", isOn: $model.showDockIcon)
                Text("Turn off the Dock icon to run as a menu-bar-only app. At least one of these stays on so the app remains reachable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 400)
    }
}

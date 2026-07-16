import SwiftUI

/// The Settings window (⌘,). Holds recording quality, save location, and how the
/// app presents itself (menu bar and/or Dock).
struct SettingsView: View {
    @ObservedObject var model: RecorderModel
    @AppStorage(Appearance.showMenuBarKey) private var showMenuBarIcon = true
    @AppStorage(Appearance.showDockKey) private var showDockIcon = true
    @AppStorage(Transcriber.modelKey) private var whisperModel = Transcriber.Model.tiny.rawValue
    @AppStorage(Transcriber.languageKey) private var whisperLanguage = "auto"
    @AppStorage(Transcriber.translateKey) private var whisperTranslate = false

    /// Common whisper languages for the picker (code, display name).
    private let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("ru", "Russian"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("ar", "Arabic")
    ]

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

            Section("Transcription") {
                Picker("Model", selection: $whisperModel) {
                    ForEach(Transcriber.Model.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                Picker("Language", selection: $whisperLanguage) {
                    ForEach(languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                Toggle("Translate to English", isOn: $whisperTranslate)
                if Transcriber.isAvailable {
                    Text("Transcripts are saved as .srt in a “Transcripts” sub-folder next to your recordings. Larger models are more accurate but slower and download once on first use.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("whisper-cli isn’t installed. Install it with: brew install whisper-cpp")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Appearance") {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { showMenuBarIcon },
                    set: { on in
                        showMenuBarIcon = on
                        if !on && !showDockIcon { showDockIcon = true }  // stay reachable
                    }))
                Toggle("Show Dock icon", isOn: Binding(
                    get: { showDockIcon },
                    set: { on in
                        showDockIcon = on
                        if !on && !showMenuBarIcon { showMenuBarIcon = true }  // stay reachable
                        Appearance.applyDockPolicy(showDockIcon)
                    }))
                Text("Turn off the Dock icon to run as a menu-bar-only app. At least one of these stays on so the app remains reachable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }
}

import SwiftUI

/// Lets the user choose whether to record all system audio or just one app.
/// Shared by the main window and the menu-bar panel.
struct SourcePicker: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isApp ? "app.dashed" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Picker("Record from", selection: Binding(
                get: { model.source },
                set: { model.selectSource($0) })) {
                Text("All system audio").tag(AudioSource.system)
                if !options.isEmpty {
                    Divider()
                    ForEach(options) { app in
                        Text(app.name).tag(AudioSource.app(bundleID: app.bundleID))
                    }
                }
            }
            .labelsHidden()
            .disabled(model.isRecording)

            Button {
                Task { await model.refreshApps() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh the list of running apps")
            .disabled(model.isRecording)
        }
        .task { await model.refreshApps() }
    }

    private var isApp: Bool {
        if case .app = model.source { return true }
        return false
    }

    /// The pickable apps, guaranteeing the currently-selected app is present even
    /// if it isn't running right now (so the picker still shows its name).
    private var options: [AudioApp] {
        var list = model.availableApps
        if case .app(let bid) = model.source,
           !list.contains(where: { $0.bundleID == bid }) {
            let name = (model.sourceName ?? bid) + " (not running)"
            list.insert(AudioApp(bundleID: bid, name: name), at: 0)
        }
        return list
    }
}

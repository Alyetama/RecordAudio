import SwiftUI

/// Shown when macOS hasn't granted Screen Recording permission (its only channel
/// for capturing system audio).
struct PermissionBanner: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Recording permission required")
                .font(.caption).fontWeight(.semibold)
            Text("macOS routes system-audio capture through Screen Recording. Enable RecordAudio there, then record again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") { model.openPrivacySettings() }
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

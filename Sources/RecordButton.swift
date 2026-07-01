import SwiftUI

/// The record / stop button, shared by the main window and the menu-bar panel.
struct RecordButton: View {
    @ObservedObject var model: RecorderModel
    var large: Bool = false

    var body: some View {
        Button(action: { model.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    .foregroundStyle(model.isRecording ? .white : .red)
                Text(model.isRecording ? "Stop" : "Record")
                    .fontWeight(.semibold)
                Spacer()
                if model.isRecording {
                    Text(model.elapsedString)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .font(large ? .title3 : .body)
            .padding(.vertical, large ? 12 : 8)
            .padding(.horizontal, large ? 16 : 12)
            .frame(maxWidth: .infinity)
            .background(model.isRecording ? Color.red : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.25),
                            lineWidth: model.isRecording ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

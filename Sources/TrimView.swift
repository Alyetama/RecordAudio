import SwiftUI

/// The Trim editor window: shows the recording's waveform with two draggable
/// handles (and matching sliders) to pick where the audio starts and ends, a
/// preview player, and Save / Cancel.
struct TrimView: View {
    @StateObject private var model: TrimModel
    /// Called with `true` if a trimmed file was saved, `false` on cancel.
    let onClose: (Bool) -> Void

    init(url: URL, onClose: @escaping (Bool) -> Void) {
        _model = StateObject(wrappedValue: TrimModel(url: url))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trim Recording").font(.headline)
                Text(model.url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            if model.isLoading {
                loading
            } else if model.loadFailed {
                Text("Couldn't read this recording.")
                    .foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                editor
            }

            if let msg = model.errorMessage {
                Text(msg).font(.caption).foregroundStyle(.red)
            }

            Divider()
            footer
        }
        .padding(18)
        .frame(width: 640, height: 460)
        .task { await model.load() }
        .onDisappear { model.cleanup() }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Analyzing audio…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var editor: some View {
        VStack(spacing: 14) {
            WaveformSelector(
                samples: model.samples,
                duration: model.duration,
                start: $model.startTime,
                end: $model.endTime,
                playhead: model.playhead,
                onSeek: { model.seek(to: $0) })
            .frame(height: 150)

            // Time readout
            HStack {
                label("Start", time(model.startTime))
                Spacer()
                label("Selection", time(model.endTime - model.startTime), highlight: true)
                Spacer()
                label("End", time(model.endTime))
            }

            // Precise sliders
            VStack(spacing: 6) {
                sliderRow("Start", value: Binding(
                    get: { model.startTime },
                    set: { model.startTime = min($0, model.endTime - model.minimumGap) }))
                sliderRow("End", value: Binding(
                    get: { model.endTime },
                    set: { model.endTime = max($0, model.startTime + model.minimumGap) }))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.togglePlay()
            } label: {
                Label(model.isPlaying ? "Pause" : "Play",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(model.isLoading || model.loadFailed)

            Spacer()

            Button("Cancel") { onClose(false) }
                .keyboardShortcut(.cancelAction)

            Button {
                Task { if await model.save() { onClose(true) } }
            } label: {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save Trimmed")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isLoading || model.loadFailed || model.isSaving
                      || model.endTime - model.startTime < model.minimumGap)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Slider(value: value, in: 0...max(model.duration, 0.01))
        }
    }

    private func label(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
                .foregroundStyle(highlight ? Color.accentColor : .primary)
        }
    }

    private func time(_ t: Double) -> String {
        let clamped = max(0, t)
        let minutes = Int(clamped) / 60
        let seconds = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }
}

// MARK: - Waveform + range handles

private struct WaveformSelector: View {
    let samples: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    let onSeek: (Double) -> Void

    private var minGap: Double { max(0.05, duration * 0.01) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sx = x(for: start, w)
            let ex = x(for: end, w)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))

                WaveformShape(samples: samples)
                    .fill(Color.secondary.opacity(0.35))

                WaveformShape(samples: samples)
                    .fill(Color.accentColor)
                    .mask(Rectangle()
                        .frame(width: max(0, ex - sx))
                        .position(x: (sx + ex) / 2, y: h / 2))

                // Dim the parts outside the selection.
                Rectangle().fill(.black.opacity(0.30))
                    .frame(width: max(0, sx)).position(x: sx / 2, y: h / 2)
                Rectangle().fill(.black.opacity(0.30))
                    .frame(width: max(0, w - ex)).position(x: (ex + w) / 2, y: h / 2)

                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: max(0, ex - sx), height: h)
                    .position(x: (sx + ex) / 2, y: h / 2)

                // Scrub layer: click or drag anywhere to move the playhead.
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                        .onChanged { v in onSeek(time(for: v.location.x, w)) })

                handle(x: sx, h: h)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                        .onChanged { v in
                            start = clamp(time(for: v.location.x, w), 0, end - minGap)
                        })
                handle(x: ex, h: h)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                        .onChanged { v in
                            end = clamp(time(for: v.location.x, w), start + minGap, duration)
                        })

                // Playhead — always visible, non-interactive (scrub layer handles drags).
                Rectangle().fill(.white).frame(width: 2, height: h)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .position(x: x(for: playhead, w), y: h / 2)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "wave")
        }
    }

    private func handle(x: CGFloat, h: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.accentColor).frame(width: 3, height: h)
            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                .frame(width: 12, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.8), lineWidth: 1))
        }
        .frame(width: 26, height: h)     // wide, easy-to-grab hit area
        .contentShape(Rectangle())
        .position(x: x, y: h / 2)
    }

    private func x(for t: Double, _ w: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(t / duration) * w : 0
    }
    private func time(for x: CGFloat, _ w: CGFloat) -> Double {
        w > 0 ? Double(x / w) * duration : 0
    }
    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), max(lo, hi))
    }
}

private struct WaveformShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let mid = rect.midY
        let barWidth = rect.width / CGFloat(samples.count)
        for (i, s) in samples.enumerated() {
            let barHeight = max(1, CGFloat(s) * rect.height * 0.92)
            let x = CGFloat(i) * barWidth
            path.addRect(CGRect(x: x, y: mid - barHeight / 2,
                                width: max(0.5, barWidth * 0.8), height: barHeight))
        }
        return path
    }
}

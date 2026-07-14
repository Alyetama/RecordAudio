import Foundation
import SwiftUI
import AVFoundation
import CoreMedia

/// Drives the Trim editor window: loads a waveform for the recording, previews
/// the selected region, and saves the chosen `[start, end]` range.
@MainActor
final class TrimModel: ObservableObject {
    let url: URL

    @Published var isLoading = true
    @Published var loadFailed = false
    @Published var duration: Double = 0
    @Published var samples: [Float] = []      // normalized 0...1 peaks

    @Published var startTime: Double = 0
    @Published var endTime: Double = 0

    @Published var isPlaying = false
    @Published var playhead: Double = 0

    @Published var isSaving = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var displayTimer: Timer?

    /// Smallest selectable gap so the two handles can't cross.
    var minimumGap: Double { max(0.05, duration * 0.01) }

    init(url: URL) { self.url = url }

    // MARK: - Load

    func load() async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else {
            isLoading = false
            loadFailed = true
            return
        }
        let wave = await Self.generateWaveform(url: url, bins: 500)

        duration = seconds
        samples = wave
        startTime = 0
        endTime = seconds
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        isLoading = false
    }

    // MARK: - Preview playback (of the selected region)

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    private func play() {
        guard let player else { return }
        if playhead >= duration - 0.03 { playhead = 0 }   // restart if parked at end
        player.currentTime = playhead
        player.play()
        isPlaying = true
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        guard let player else { return }
        if player.isPlaying {
            playhead = player.currentTime
        } else {
            pause()   // reached end of file
        }
    }

    /// Move the playhead anywhere in the file; audible immediately if playing.
    func seek(to time: Double) {
        let t = min(max(0, time), duration)
        playhead = t
        player?.currentTime = t
    }

    // MARK: - Save

    func save() async -> Bool {
        pause()
        player = nil                 // release the file handle before replacing it
        isSaving = true
        defer { isSaving = false }
        do {
            try await AudioTrimmer.trim(url: url, start: startTime, end: endTime)
            return true
        } catch {
            errorMessage = error.localizedDescription
            player = try? AVAudioPlayer(contentsOf: url)   // restore preview
            return false
        }
    }

    func cleanup() {
        pause()
        player = nil
    }

    // MARK: - Waveform

    /// Decodes PCM and reduces it to `bins` normalized peak values. Runs off the
    /// main actor (nonisolated) so the scan never blocks the UI.
    nonisolated private static func generateWaveform(url: URL, bins: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let durationSec = try? await asset.load(.duration).seconds,
              durationSec > 0,
              let formats = try? await track.load(.formatDescriptions),
              let format = formats.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return [] }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
        guard sampleRate > 0 else { return [] }
        let totalFrames = Int(durationSec * sampleRate)
        let framesPerBin = max(1, totalFrames / max(1, bins))

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { return [] }

        var result: [Float] = []
        result.reserveCapacity(bins + 1)
        var binPeak: Int16 = 0
        var framesInBin = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                let pointer else { continue }

            let frameCount = length / (2 * channels)
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { s in
                var frame = 0
                while frame < frameCount {
                    var peak: Int16 = 0
                    let base = frame * channels
                    for c in 0..<channels {
                        let v = s[base + c]
                        let a = v == Int16.min ? Int16.max : abs(v)
                        if a > peak { peak = a }
                    }
                    if peak > binPeak { binPeak = peak }
                    framesInBin += 1
                    if framesInBin >= framesPerBin {
                        result.append(Float(binPeak) / Float(Int16.max))
                        binPeak = 0
                        framesInBin = 0
                    }
                    frame += 1
                }
            }
        }
        if framesInBin > 0 { result.append(Float(binPeak) / Float(Int16.max)) }

        // Normalize so the tallest peak fills the view.
        if let maxV = result.max(), maxV > 0 {
            result = result.map { min(1, $0 / maxV) }
        }
        return result
    }
}

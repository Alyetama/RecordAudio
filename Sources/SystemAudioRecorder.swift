import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Records the Mac's *system* audio (everything the computer plays — not the
/// microphone) using ScreenCaptureKit and encodes it straight to AAC in an
/// `.m4a` container. AAC keeps the files small while sounding good.
///
/// macOS gates system-audio capture behind the **Screen Recording** privacy
/// permission, so the first recording will trigger that prompt.
///
/// Thread-safety: every access to the mutable capture state below happens on
/// `sampleQueue`. That queue is both the ScreenCaptureKit sample-delivery queue
/// and the lock that serializes `start()`/`stop()`, so there is no data race
/// between an in-flight sample buffer and teardown.
final class SystemAudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?

    private let sampleQueue = DispatchQueue(label: "com.fcatus.recordaudio.samples")

    /// Called (on an arbitrary queue) if the capture stops unexpectedly, e.g.
    /// the user revoked Screen Recording permission mid-recording.
    var onError: ((Error) -> Void)?

    // MARK: - Start

    /// - Parameters:
    ///   - url: destination `.m4a` file (must not already exist).
    ///   - bitrate: AAC bitrate in bits/sec (e.g. 128_000).
    func start(to url: URL, bitrate: Int) async throws {
        // Pick a display to attach the capture to. Audio capture still needs a
        // content filter, but since we never register a video output no frames
        // are ever delivered to us — this is effectively audio-only.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't record our own app
        config.sampleRate = 48_000
        config.channelCount = 2
        // Keep the (unused) video pipeline as cheap as possible.
        config.width = 128
        config.height = 72
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        // AAC encoder writing to .m4a.
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitrate
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
        writer.add(input)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        // Publish state to the sample queue before capture can deliver anything.
        sampleQueue.sync {
            self.writer = writer
            self.audioInput = input
            self.outputURL = url
            self.stream = stream
            self.sessionStarted = false
        }

        do {
            try await stream.startCapture()
        } catch {
            // Roll back the half-initialized state so the next attempt is clean.
            _ = await stop()
            throw error
        }
    }

    // MARK: - Stop

    /// Stops capture, finalizes the file, and returns the written URL (or nil if
    /// nothing was captured). Safe to call more than once / concurrently: the
    /// first call takes ownership of the state and any later call is a no-op.
    @discardableResult
    func stop() async -> URL? {
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var url: URL?
        var stream: SCStream?
        sampleQueue.sync {
            writer = self.writer; input = self.audioInput
            url = self.outputURL; stream = self.stream
            self.writer = nil; self.audioInput = nil
            self.outputURL = nil; self.stream = nil
            self.sessionStarted = false
        }

        guard writer != nil || stream != nil else { return nil }

        if let stream { try? await stream.stopCapture() }   // no more callbacks after this

        // Only finalize if we actually began writing; otherwise no file exists.
        if let writer, writer.status == .writing {
            input?.markAsFinished()
            await withCheckedContinuation { cont in
                writer.finishWriting { cont.resume() }
            }
            return url
        }
        return nil
    }

    // MARK: - SCStreamOutput  (invoked on sampleQueue)

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writer = writer,
              let input = audioInput,
              writer.status != .failed else { return }

        if !sessionStarted {
            if writer.status == .unknown {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
            }
            sessionStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

enum RecorderError: LocalizedError {
    case noDisplay
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .noDisplay:     return "No display was available to attach the audio capture to."
        case .cannotAddInput: return "Could not set up the AAC audio encoder."
        }
    }
}

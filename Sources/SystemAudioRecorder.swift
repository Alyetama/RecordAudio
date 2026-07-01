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
final class SystemAudioRecorder: NSObject, SCStreamDelegate, SCStreamOutput {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?

    private let sampleQueue = DispatchQueue(label: "com.fcatus.recordaudio.samples")

    /// Called (on an arbitrary queue) if the capture stops unexpectedly, e.g.
    /// the user revoked Screen Recording permission.
    var onError: ((String) -> Void)?

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

        self.writer = writer
        self.audioInput = input
        self.outputURL = url
        self.sessionStarted = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    // MARK: - Stop

    /// Stops capture, finalizes the file, and returns the written URL.
    @discardableResult
    func stop() async -> URL? {
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // No more sample buffers will arrive after stopCapture() returns.
        audioInput?.markAsFinished()

        let finished = outputURL
        if let writer = writer, writer.status == .writing {
            await withCheckedContinuation { cont in
                writer.finishWriting { cont.resume() }
            }
        }

        writer = nil
        audioInput = nil
        outputURL = nil
        sessionStarted = false
        return finished
    }

    // MARK: - SCStreamOutput

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
        onError?(error.localizedDescription)
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

import Foundation

/// Transcribes a recording with a local whisper.cpp `whisper-cli` binary and the
/// **tiny** ggml model. Everything runs on-device — no network except a one-time
/// model download on first use.
///
/// Resolution order for the binary: a copy bundled in the app's Resources, then
/// Homebrew's `whisper-cli`. The model is cached in Application Support.
enum Transcriber {

    enum TranscribeError: LocalizedError {
        case noBinary
        case conversionFailed
        case modelDownloadFailed
        case whisperFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBinary:
                return "whisper-cli isn't available. Install it with: brew install whisper-cpp"
            case .conversionFailed:
                return "Couldn't prepare the audio for transcription."
            case .modelDownloadFailed:
                return "Couldn't download the Whisper tiny model."
            case .whisperFailed(let s):
                return "Transcription failed. \(s)"
            }
        }
    }

    private static let modelURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!

    /// Transcribes `audioURL`, writes a sidecar `.txt` next to it, and returns the text.
    static func transcribe(_ audioURL: URL) async throws -> String {
        guard let cli = whisperCLI() else { throw TranscribeError.noBinary }
        let model = try await ensureModel()

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // whisper.cpp wants 16 kHz mono 16-bit WAV.
        let wav = work.appendingPathComponent("audio.wav")
        try convertToWAV(source: audioURL, destination: wav)

        let outBase = work.appendingPathComponent("out")
        let result = try run(cli, [
            "-m", model.path,
            "-f", wav.path,
            "-otxt", "-of", outBase.path,
            "-nt",                       // no per-line timestamps
            "-t", "\(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))"
        ])
        guard result.status == 0 else {
            throw TranscribeError.whisperFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let txtURL = outBase.appendingPathExtension("txt")
        let text = ((try? String(contentsOf: txtURL, encoding: .utf8)) ?? result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Save a sidecar .txt beside the recording.
        let sidecar = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try? text.write(to: sidecar, atomically: true, encoding: .utf8)

        return text
    }

    static var isAvailable: Bool { whisperCLI() != nil }

    // MARK: - Binary / model resolution

    private static func whisperCLI() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func modelLocation() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("RecordAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("ggml-tiny.bin")
    }

    private static func ensureModel() async throws -> URL {
        let dest = try modelLocation()
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if FileManager.default.fileExists(atPath: dest.path), size > 1_000_000 {
            return dest
        }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: modelURL)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            throw TranscribeError.modelDownloadFailed
        }
    }

    // MARK: - Helpers

    private static func convertToWAV(source: URL, destination: URL) throws {
        let result = try run(URL(fileURLWithPath: "/usr/bin/afconvert"),
            [source.path, destination.path, "-d", "LEI16@16000", "-c", "1", "-f", "WAVE"])
        guard result.status == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw TranscribeError.conversionFailed
        }
    }

    private struct ProcResult { let status: Int32; let stdout: String; let stderr: String }

    private static func run(_ executable: URL, _ args: [String]) throws -> ProcResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}

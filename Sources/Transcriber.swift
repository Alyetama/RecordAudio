import Foundation

extension Notification.Name {
    /// Posted (with the audio `URL` as `object`) after a transcript is written.
    static let transcriptSaved = Notification.Name("RecordAudio.transcriptSaved")
}

/// Transcribes a recording with a local whisper.cpp `whisper-cli` binary and the
/// **tiny** ggml model. Everything runs on-device — no network except a one-time
/// model download on first use. Output is an `.srt` subtitle file with timestamps.
///
/// Resolution order for the binary: a copy bundled in the app's Resources, then
/// Homebrew's `whisper-cli`. The model is cached in Application Support.
enum Transcriber {

    /// Coarse progress signals for the UI. Percentages are 0…1.
    enum Progress: Sendable, Equatable {
        case downloadingModel(Double)
        case preparingAudio
        case transcribing(Double)
    }

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

    // MARK: - Settings (persisted in UserDefaults, edited from the Settings window)

    static let modelKey = "whisperModel"
    static let languageKey = "whisperLanguage"
    static let translateKey = "whisperTranslate"

    /// Which ggml model to use. Bigger = more accurate but slower and larger.
    /// `rawValue` matches the huggingface filename stem (`ggml-<rawValue>.bin`).
    enum Model: String, CaseIterable, Identifiable {
        case tiny
        case base
        case small
        case medium
        case largeTurbo = "large-v3-turbo"
        case large      = "large-v3"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .tiny:       return "Tiny — fastest, ~75 MB"
            case .base:       return "Base — balanced, ~142 MB"
            case .small:      return "Small — accurate, ~466 MB"
            case .medium:     return "Medium — more accurate, ~1.5 GB"
            case .largeTurbo: return "Large v3 Turbo — fast & very accurate, ~1.6 GB"
            case .large:      return "Large v3 — best accuracy, ~2.9 GB"
            }
        }
        var fileName: String { "ggml-\(rawValue).bin" }
        var downloadURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
        }
    }

    static var selectedModel: Model {
        Model(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .tiny
    }

    /// BCP-47-ish language code whisper understands, or "auto" to detect.
    private static var language: String {
        let v = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        return v.isEmpty ? "auto" : v
    }

    /// Whether to translate the speech into English rather than transcribe as-is.
    private static var translateToEnglish: Bool {
        UserDefaults.standard.bool(forKey: translateKey)
    }

    /// True once the *currently selected* model is cached locally — lets the UI
    /// skip the "first run downloads…" state when there's nothing to download.
    static var isModelPresent: Bool {
        guard let dest = try? modelLocation(for: selectedModel) else { return false }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return FileManager.default.fileExists(atPath: dest.path) && size > 1_000_000
    }

    // MARK: - Transcript file locations

    /// Sub-folder (beside the audio) where transcripts are written, keeping them
    /// out of the recordings folder itself.
    static func transcriptsFolder(for audioURL: URL) -> URL {
        audioURL.deletingLastPathComponent()
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// Where the `.srt` for a given recording lives.
    static func transcriptURL(for audioURL: URL) -> URL {
        transcriptsFolder(for: audioURL)
            .appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("srt")
    }

    /// True if this recording already has a transcript on disk.
    static func hasTranscript(for audioURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(for: audioURL).path)
    }

    /// Transcribes `audioURL`, writes a sidecar `.srt` next to it, and returns the
    /// SRT text. `onProgress` is called (possibly off the main thread) as work
    /// advances — hop to the main actor before touching UI.
    static func transcribe(_ audioURL: URL,
                           onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> String {
        guard let cli = whisperCLI() else { throw TranscribeError.noBinary }
        let model = try await ensureModel(selectedModel, onProgress: onProgress)

        onProgress(.preparingAudio)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // whisper.cpp wants 16 kHz mono 16-bit WAV.
        let wav = work.appendingPathComponent("audio.wav")
        try convertToWAV(source: audioURL, destination: wav)

        onProgress(.transcribing(0))

        let outBase = work.appendingPathComponent("out")
        var args = [
            "-m", model.path,
            "-f", wav.path,
            "-osrt", "-of", outBase.path,   // SubRip subtitles, with timestamps
            "-pp",                          // print progress to stderr
            "-l", language,                 // "auto" detects the language
            "-t", "\(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))"
        ]
        if translateToEnglish { args.append("-tr") }   // translate speech to English
        let result = try run(cli, args, onStderrLine: { line in
            if let pct = parseProgress(line) { onProgress(.transcribing(pct)) }
        })
        guard result.status == 0 else {
            throw TranscribeError.whisperFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let srtURL = outBase.appendingPathExtension("srt")
        let raw = ((try? String(contentsOf: srtURL, encoding: .utf8)) ?? result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // whisper prefixes each segment's text with a space — drop leading spaces.
        let text = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop(while: { $0 == " " })
                return trimmed.isEmpty ? String(line) : String(trimmed)
            }
            .joined(separator: "\n")

        // Save the .srt into a Transcripts sub-folder beside the recording.
        let dest = transcriptURL(for: audioURL)
        try? FileManager.default.createDirectory(
            at: transcriptsFolder(for: audioURL), withIntermediateDirectories: true)
        try? text.write(to: dest, atomically: true, encoding: .utf8)

        // Let open windows (e.g. History) refresh their "transcribed" state.
        NotificationCenter.default.post(name: .transcriptSaved, object: audioURL)

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

    private static func modelLocation(for model: Model) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("RecordAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(model.fileName)
    }

    private static func ensureModel(_ model: Model,
                                    onProgress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let dest = try modelLocation(for: model)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if FileManager.default.fileExists(atPath: dest.path), size > 1_000_000 { return dest }
        do {
            onProgress(.downloadingModel(0))
            let downloader = ModelDownloader { onProgress(.downloadingModel($0)) }
            let tmp = try await downloader.download(model.downloadURL)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            throw TranscribeError.modelDownloadFailed
        }
    }

    /// Parses a whisper.cpp `-pp` progress line, e.g. "…: progress =  20%".
    private static func parseProgress(_ line: String) -> Double? {
        guard let r = line.range(of: "progress =") else { return nil }
        let numStr = line[r.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .prefix { $0.isNumber }
        guard let n = Double(numStr) else { return nil }
        return min(1, max(0, n / 100))
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

    /// Runs `executable`. If `onStderrLine` is set, stderr is streamed line by
    /// line as it arrives (used to surface live progress); the full stderr is
    /// still returned in the result.
    private static func run(_ executable: URL, _ args: [String],
                            onStderrLine: (@Sendable (String) -> Void)? = nil) throws -> ProcResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collector = StderrCollector(onLine: onStderrLine)
        if onStderrLine != nil {
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collector.append(chunk) }
            }
        }

        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()

        if onStderrLine != nil {
            process.waitUntilExit()
            err.fileHandleForReading.readabilityHandler = nil
            let remaining = err.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty { collector.append(remaining) }
        } else {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            collector.append(errData)
            process.waitUntilExit()
        }

        return ProcResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: collector.string)
    }
}

/// Accumulates a process's stderr and, if given a handler, emits newline-delimited
/// lines as they arrive. Thread-safe — the readability handler fires off-thread.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        guard let onLine else { return }
        pending.append(chunk)
        // whisper ends progress lines with \n; split on \n and \r just in case.
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<idx]
            if !lineData.isEmpty, let s = String(data: lineData, encoding: .utf8) { onLine(s) }
            pending.removeSubrange(pending.startIndex...idx)
        }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Downloads a file with byte-level progress via `URLSessionDownloadDelegate`.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns — move it out first.
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            continuation?.resume(returning: dst)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

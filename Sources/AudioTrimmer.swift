import Foundation
import AVFoundation
import CoreMedia

/// Exports a chosen `[start, end]` range of an `.m4a` recording, replacing the
/// original file in place.
///
/// Uses `AVAssetExportPresetPassthrough`, which copies the existing AAC data for
/// the kept range instead of re-encoding it — trimming never touches quality or
/// bitrate.
enum AudioTrimmer {
    enum TrimError: LocalizedError {
        case exportUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .exportUnavailable: return "Couldn't set up the audio exporter."
            case .exportFailed:      return "The trim couldn't be saved."
            }
        }
    }

    static func trim(url: URL, start: Double, end: Double) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let clampedStart = max(0, min(start, duration))
        let clampedEnd = max(clampedStart, min(end, duration))

        let range = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            end: CMTime(seconds: clampedEnd, preferredTimescale: 600))

        // Write to a sibling temp file, then atomically swap it into place.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")

        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TrimError.exportUnavailable
        }
        exporter.outputURL = tempURL
        exporter.outputFileType = .m4a
        exporter.timeRange = range

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }

        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: tempURL)
            throw TrimError.exportFailed
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}

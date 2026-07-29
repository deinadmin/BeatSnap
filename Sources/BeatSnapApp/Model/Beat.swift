import Foundation

/// A downloaded, analysed beat. Mirrors the JSON shape of the original library index so
/// an existing `beats.json` stays readable.
struct Beat: Codable, Identifiable, Hashable {
    var id: String
    /// Original video title.
    var title: String
    /// Final filename including BPM/key, e.g. "Title [140BPM F#min].wav".
    var fileName: String
    /// Absolute path to the WAV on disk.
    var filePath: String
    var bpm: Int
    /// Full key name, e.g. "F# minor".
    var key: String
    var durationSec: Int
    /// Milliseconds since epoch, matching the original index.
    var createdAt: Double
    /// Used to skip re-downloading the same video.
    var youtubeId: String?

    var fileURL: URL { URL(fileURLWithPath: filePath) }

    var existsOnDisk: Bool { FileManager.default.fileExists(atPath: filePath) }

    var durationText: String {
        guard durationSec > 0 else { return "" }
        return String(format: "%d:%02d", durationSec / 60, durationSec % 60)
    }

    static func makeID() -> String {
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return "\(Int(Date().timeIntervalSince1970 * 1000))-\(suffix)"
    }
}

/// Stages of the download pipeline, surfaced as a live row in the list.
enum DownloadStage: Equatable {
    case starting
    case downloading(progress: Double?)
    case converting
    case analyzing
    case saving

    var label: String {
        switch self {
        case .starting: "Starting download…"
        case .downloading(let progress):
            if let progress { String(format: "Downloading… %.0f%%", progress * 100) }
            else { "Downloading…" }
        case .converting: "Converting to WAV…"
        case .analyzing: "Analyzing BPM & key…"
        case .saving: "Saving…"
        }
    }
}

struct DownloadJob: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var stage: DownloadStage
}

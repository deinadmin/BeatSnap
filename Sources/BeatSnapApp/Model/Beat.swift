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

/// Stages of the import pipeline, surfaced as a live row above the library.
enum QueueStage: Equatable {
    case waiting
    case starting
    case downloading(progress: Double?)
    case converting
    case analyzing
    case saving
    /// Terminal. The row sticks around carrying the reason, because the panel may well have
    /// been closed when this happened.
    case failed(String)

    var label: String {
        switch self {
        case .waiting: "Queued"
        case .starting: "Starting download…"
        case .downloading(let progress):
            if let progress { String(format: "Downloading… %.0f%%", progress * 100) }
            else { "Downloading…" }
        case .converting: "Converting to WAV…"
        case .analyzing: "Analyzing BPM & key…"
        case .saving: "Saving…"
        case .failed(let reason): reason
        }
    }

    var isWaiting: Bool { self == .waiting }

    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }

    /// Download progress, when it's known.
    var progress: Double? {
        if case .downloading(let progress) = self { progress } else { nil }
    }
}

/// One unit of queued work. A YouTube link and a dropped file differ only in how the audio
/// arrives — both end as an analysed file in the beats folder — so they share a queue.
struct QueueItem: Identifiable, Equatable {
    enum Source: Equatable {
        case youtube(url: String, info: VideoInfo)
        case file(URL)
    }

    let id = UUID()
    var title: String
    var source: Source
    var stage: QueueStage = .waiting

    var videoID: String? {
        if case .youtube(_, let info) = source { info.id } else { nil }
    }

    var fileURL: URL? {
        if case .file(let url) = source { url } else { nil }
    }
}

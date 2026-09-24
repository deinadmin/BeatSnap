import Foundation

/// A tagged audio file in the selected beats folder, including cloud-only items.
struct Beat: Codable, Identifiable, Hashable {
    var id: String
    /// Title without the trailing analysis tag.
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
    /// Metadata-only files stay visible without opening their audio or starting a download.
    var needsDownload = false

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

/// A user-selectable musical key. BeatSnap deliberately uses flats for the black keys
/// where the analyzer does, keeping display names and filename tags consistent.
struct BeatKey: Hashable {
    enum Mode: String, CaseIterable, Identifiable {
        case minor
        case major

        var id: Self { self }
        var label: String { rawValue.capitalized }
        var filenameSuffix: String { self == .minor ? "min" : "maj" }
    }

    static let tonics = ["A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"]

    let tonic: String
    let mode: Mode

    init(tonic: String, mode: Mode) {
        self.tonic = tonic
        self.mode = mode
    }

    init?(displayName: String) {
        let parts = displayName.split(separator: " ")
        guard parts.count == 2,
              Self.tonics.contains(String(parts[0])),
              let mode = Mode(rawValue: String(parts[1]))
        else { return nil }
        self.init(tonic: String(parts[0]), mode: mode)
    }

    var displayName: String { "\(tonic) \(mode.rawValue)" }
    var filenameName: String { "\(tonic)\(mode.filenameSuffix)" }
}

/// Fresh analyzer output shown as a draft in the label editor until the user saves it.
struct BeatLabelAnalysis {
    let bpm: Int
    let key: BeatKey
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

/// One unit of queued work. A link and a dropped file differ only in how the audio
/// arrives — both end as an analysed file in the beats folder — so they share a queue.
struct QueueItem: Identifiable, Equatable {
    enum Source: Equatable {
        case youtube(url: String, info: VideoInfo)
        case remote(DownloadLink)
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

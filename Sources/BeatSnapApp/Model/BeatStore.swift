import Foundation

/// Persistence for the beat library: WAVs live in the chosen download folder, their
/// metadata in `<Application Support>/BeatSnap/beats.json`.
struct BeatStore {
    static let shared = BeatStore()

    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("BeatSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    var indexURL: URL { supportDirectory.appendingPathComponent("beats.json") }

    var defaultBeatsDirectory: URL {
        supportDirectory.appendingPathComponent("beats", isDirectory: true)
    }

    /// Where new downloads land: the user's chosen folder, else the default.
    func beatsDirectory() -> URL {
        let directory = AppSettings.shared.downloadDirectory ?? defaultBeatsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func load() -> [Beat] {
        guard let data = try? Data(contentsOf: indexURL),
              let beats = try? JSONDecoder().decode([Beat].self, from: data)
        else { return [] }
        return beats.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ beats: [Beat]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(beats) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Strip characters that are awkward or illegal in macOS filenames.
    static func sanitize(filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "[/\\\\:*?\"<>| -]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(cleaned.prefix(120))
        return clipped.isEmpty ? "Untitled Beat" : clipped
    }

    /// Resolve a non-colliding path by appending " (n)" before the extension.
    static func uniqueURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}

/// User settings, persisted in UserDefaults.
final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let downloadDirectory = "downloadDirectoryBookmark"
        static let downloadDirectoryPath = "downloadDirectoryPath"
        static let lastToolUpdateCheck = "lastToolUpdateCheck"
    }

    /// nil means "use the default folder".
    var downloadDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Keys.downloadDirectoryPath),
                  !path.isEmpty
            else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: Keys.downloadDirectoryPath)
        }
    }

    var lastToolUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastToolUpdateCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastToolUpdateCheck) }
    }
}

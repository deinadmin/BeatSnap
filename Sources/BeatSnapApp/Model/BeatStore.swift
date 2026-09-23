import Foundation

/// Locations and filename conventions for the folder-backed beat library.
struct BeatStore {
    static let shared = BeatStore()

    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("BeatSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }

    var defaultBeatsDirectory: URL {
        supportDirectory.appendingPathComponent("beats", isDirectory: true)
    }

    /// Where new downloads land: the user's chosen folder, else the default.
    func beatsDirectory() -> URL {
        let directory = AppSettings.shared.downloadDirectory ?? defaultBeatsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether `url` already sits directly in the beats folder, in which case an import can
    /// rename it in place instead of leaving a second copy of the same audio behind.
    func isInBeatsDirectory(_ url: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            == beatsDirectory().resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Drop a trailing " [140BPM F#min]" tag, plus the " (2)" that `uniqueURL` may have added
    /// right after it.
    ///
    /// Re-analysing a file BeatSnap (or the original app) already named would otherwise give
    /// "title [140BPM F#min] [140BPM F#min]". Tonics are A-referenced with flats, so the key
    /// is one of A-G plus an optional # or b. The "(n)" is only stripped when it directly
    /// follows a tag — plenty of beat titles legitimately end in "(2023)".
    static func stripAnalysisTag(from name: String) -> String {
        name.replacingOccurrences(
            of: #"\s*\[\d+BPM [A-G][#b]?(min|maj)\](\s*\(\d+\))?$"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespaces)
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
        static let analysisAlgorithm = "analysisAlgorithm"
        static let keepBeatSnapOnTop = "keepBeatSnapOnTop"
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

    var keepBeatSnapOnTop: Bool {
        get { UserDefaults.standard.object(forKey: Keys.keepBeatSnapOnTop) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.keepBeatSnapOnTop) }
    }

    /// The preferred analyzer for newly queued work. Apple is the default wherever the
    /// framework exists; older macOS releases continue with BeatSnap's original DSP.
    var analysisAlgorithm: AnalysisAlgorithm {
        get {
            if let rawValue = UserDefaults.standard.string(forKey: Keys.analysisAlgorithm),
               let stored = AnalysisAlgorithm(rawValue: rawValue) {
                return stored
            }
            if #available(macOS 27.0, *) { return .musicUnderstanding }
            return .beatSnapDSP
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.analysisAlgorithm)
        }
    }
}

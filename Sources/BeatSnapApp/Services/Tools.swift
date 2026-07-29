import Foundation

/// Locates the bundled command-line tools and keeps yt-dlp current.
///
/// yt-dlp ships inside the app so the very first launch works offline with zero setup, but
/// YouTube breaks extractors often enough that a frozen copy would rot within weeks. Newer
/// releases are therefore downloaded to Application Support and preferred over the bundled
/// one — landing *outside* the .app keeps its code signature intact.
enum Tools {
    struct Paths {
        var python: URL
        var ytdlp: URL
        var ffmpeg: URL
    }

    enum ToolError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name):
                "BeatSnap's bundled \(name) is missing. Rebuild the app to restore it."
            }
        }
    }

    static var resourcesDirectory: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    static var bundledToolsDirectory: URL {
        resourcesDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    static var updatesDirectory: URL {
        let directory = BeatStore.shared.supportDirectory.appendingPathComponent("tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The yt-dlp zipapp actually used: an updated copy if present, else the bundled one.
    static var activeYtDlp: URL {
        let updated = updatesDirectory.appendingPathComponent("yt-dlp")
        if FileManager.default.fileExists(atPath: updated.path) { return updated }
        return bundledToolsDirectory.appendingPathComponent("yt-dlp")
    }

    static func resolve() throws -> Paths {
        let python = bundledToolsDirectory
            .appendingPathComponent("python/bin/python3")
        let ffmpeg = bundledToolsDirectory.appendingPathComponent("ffmpeg")
        let ytdlp = activeYtDlp

        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: python.path) else { throw ToolError.missing("Python runtime") }
        guard manager.fileExists(atPath: ytdlp.path) else { throw ToolError.missing("yt-dlp") }
        guard manager.isExecutableFile(atPath: ffmpeg.path) else { throw ToolError.missing("ffmpeg") }

        return Paths(python: python, ytdlp: ytdlp, ffmpeg: ffmpeg)
    }

    // MARK: - Self update

    /// Check GitHub for a newer yt-dlp at most once a day, and fetch just the ~3 MB zipapp.
    static func updateYtDlpIfNeeded() async {
        if let last = AppSettings.shared.lastToolUpdateCheck,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }

        guard let paths = try? resolve() else { return }
        AppSettings.shared.lastToolUpdateCheck = Date()

        guard let latest = await latestReleaseTag() else { return }
        let current = await currentYtDlpVersion(paths: paths)
        guard current != latest else { return }

        let assetURL = URL(
            string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(latest)/yt-dlp"
        )
        guard let assetURL else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: assetURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1_000_000 else { return }

            let destination = updatesDirectory.appendingPathComponent("yt-dlp")
            let staging = destination.appendingPathExtension("download")
            try data.write(to: staging, options: .atomic)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination.path
            )
            Log.info("updated yt-dlp to \(latest)")
        } catch {
            Log.info("yt-dlp update skipped: \(error.localizedDescription)")
        }
    }

    private static func latestReleaseTag() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String
        else { return nil }
        return tag
    }

    private static func currentYtDlpVersion(paths: Paths) async -> String? {
        let result = try? await Process.run(
            executable: paths.python,
            arguments: [paths.ytdlp.path, "--version"]
        )
        return result?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Log {
    static func info(_ message: String) {
        #if DEBUG
        print("[BeatSnap] \(message)")
        #endif
    }
}

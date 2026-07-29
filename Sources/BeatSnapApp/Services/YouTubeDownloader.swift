import Foundation

struct VideoInfo {
    var id: String
    var title: String
    var durationSec: Int
}

/// Wraps the bundled yt-dlp: metadata lookups and audio downloads converted to WAV.
enum YouTubeDownloader {
    enum DownloadError: LocalizedError {
        case badURL
        case metadataFailed(String)
        case downloadFailed(String)
        case fileMissing

        var errorDescription: String? {
            switch self {
            case .badURL: "That doesn't look like a valid link."
            case .metadataFailed(let detail): detail
            case .downloadFailed(let detail): detail
            case .fileMissing: "The download finished but the audio file is missing."
            }
        }
    }

    /// Extract a YouTube video id from the usual URL shapes.
    static func youtubeID(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host else { return nil }

        if host == "youtu.be" {
            let id = components.path.replacingOccurrences(of: "/", with: "")
            return id.isEmpty ? nil : id
        }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            if let value = components.queryItems?.first(where: { $0.name == "v" })?.value, !value.isEmpty {
                return value
            }
            if components.path.hasPrefix("/shorts/") {
                let id = components.path.replacingOccurrences(of: "/shorts/", with: "")
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    /// Fetch title/duration without downloading media.
    static func fetchInfo(url: String) async throws -> VideoInfo {
        let paths = try Tools.resolve()
        let result = try await Process.run(
            executable: paths.python,
            arguments: [
                paths.ytdlp.path,
                "-J", "--no-playlist", "--no-warnings", "--skip-download",
                url,
            ]
        )

        guard result.exitCode == 0 else {
            throw DownloadError.metadataFailed(friendlyMessage(from: result.standardError))
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String
        else {
            throw DownloadError.metadataFailed("Could not read video info.")
        }

        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespaces)
        let duration = object["duration"] as? Double ?? 0
        return VideoInfo(
            id: id,
            title: (title?.isEmpty == false ? title! : "Untitled Beat"),
            durationSec: Int(duration.rounded())
        )
    }

    /// Download the best audio stream and convert it to WAV, reporting 0...1 progress.
    ///
    /// yt-dlp handles the conversion itself through the bundled ffmpeg, which keeps the
    /// Opus source (better than the AAC stream) exactly as the original app did.
    static func downloadWAV(
        url: String,
        into directory: URL,
        onProgress: @escaping @Sendable (Double?) -> Void,
        onConverting: @escaping @Sendable () -> Void
    ) async throws -> URL {
        let paths = try Tools.resolve()
        let template = directory.appendingPathComponent("%(id)s.%(ext)s").path

        let result = try await Process.run(
            executable: paths.python,
            arguments: [
                paths.ytdlp.path,
                "-x",
                "--audio-format", "wav",
                "--audio-quality", "0",
                "--no-playlist",
                "--newline",
                "--no-warnings",
                "--ffmpeg-location", paths.ffmpeg.deletingLastPathComponent().path,
                "-o", template,
                url,
            ],
            onOutputLine: { line in
                if line.contains("[ExtractAudio]") || (line.contains("Destination:") && line.contains(".wav")) {
                    onConverting()
                } else if let percent = parseProgress(line) {
                    onProgress(percent)
                }
            }
        )

        guard result.exitCode == 0 else {
            throw DownloadError.downloadFailed(friendlyMessage(from: result.standardError))
        }

        guard let id = youtubeID(from: url) ?? idFromOutput(result.standardOutput) else {
            throw DownloadError.fileMissing
        }
        let wav = directory.appendingPathComponent("\(id).wav")
        guard FileManager.default.fileExists(atPath: wav.path) else {
            throw DownloadError.fileMissing
        }
        return wav
    }

    /// `[download]  42.5% of  4.21MiB at ...`
    private static func parseProgress(_ line: String) -> Double? {
        guard line.contains("[download]"), let range = line.range(of: #"(\d+\.\d+)%"#, options: .regularExpression)
        else { return nil }
        let text = line[range].dropLast()
        guard let value = Double(text) else { return nil }
        return value / 100
    }

    private static func idFromOutput(_ output: String) -> String? {
        // "[download] Destination: /path/<id>.<ext>"
        for line in output.split(separator: "\n") where line.contains("Destination:") {
            let path = line.components(separatedBy: "Destination:").last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// yt-dlp writes a human-readable reason to stderr; surface that rather than a code.
    private static func friendlyMessage(from stderr: String) -> String {
        let errorLine = stderr
            .split(separator: "\n")
            .last(where: { $0.localizedCaseInsensitiveContains("error") })
            .map(String.init)?
            .replacingOccurrences(of: "ERROR: ", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let errorLine, !errorLine.isEmpty { return errorLine }
        return "Download failed. Check the link and try again."
    }
}

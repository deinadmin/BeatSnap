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
        case updateFailed(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name):
                "BeatSnap's bundled \(name) is missing. Rebuild the app to restore it."
            case .updateFailed(let detail):
                detail
            }
        }
    }

    /// How long a yt-dlp check is good for before the next launch looks again.
    static let updateCheckInterval: TimeInterval = 24 * 60 * 60

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

    // MARK: - Versions

    /// `yt-dlp --version` prints its release tag, which is directly comparable to GitHub's.
    static func ytDlpVersion() async -> String? {
        guard let paths = try? resolve() else { return nil }
        let result = try? await Process.run(
            executable: paths.python,
            arguments: [paths.ytdlp.path, "--version"]
        )
        guard result?.exitCode == 0 else { return nil }
        let version = result?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return version?.isEmpty == false ? version : nil
    }

    /// The first line reads "ffmpeg version 6.0 Copyright (c) …"; keep just the version.
    static func ffmpegVersion() async -> String? {
        guard let paths = try? resolve() else { return nil }
        let result = try? await Process.run(executable: paths.ffmpeg, arguments: ["-version"])
        guard let first = result?.standardOutput.split(separator: "\n").first else { return nil }
        let fields = first.split(separator: " ")
        guard fields.count > 2, fields[1] == "version" else { return nil }
        return String(fields[2])
    }

    // MARK: - Self update

    /// The newest yt-dlp release tag on GitHub, or nil if it couldn't be reached.
    static func latestYtDlpRelease() async -> String? {
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

    /// Fetch the ~3 MB zipapp for `tag` into Application Support and make it the active copy.
    ///
    /// `onProgress` reports 0...1, or nil while the total size is unknown.
    static func installYtDlp(
        tag: String,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        guard let assetURL = URL(
            string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(tag)/yt-dlp"
        ) else {
            throw ToolError.updateFailed("Couldn't work out where to download \(tag) from.")
        }

        let manager = FileManager.default
        let destination = updatesDirectory.appendingPathComponent("yt-dlp")
        // Land in a staging file first: a 404 page is a perfectly successful download as far
        // as URLSession is concerned, and overwriting a working yt-dlp with one would leave
        // the app unable to download anything at all.
        let staging = destination.appendingPathExtension("download")

        do {
            let response = try await FileDownloader(
                destination: staging, onProgress: onProgress
            ).download(from: assetURL)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ToolError.updateFailed("GitHub had no zipapp for \(tag).")
            }
            // A zipapp is a few MB; anything much smaller is a message, not a program.
            let size = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 1_000_000 else {
                throw ToolError.updateFailed("The download was incomplete. Try again.")
            }

            try? manager.removeItem(at: destination)
            try manager.moveItem(at: staging, to: destination)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            Log.info("updated yt-dlp to \(tag)")
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
}

/// Downloads one file to a fixed location, reporting progress as a 0...1 fraction.
///
/// `URLSession`'s async `download(from:delegate:)` never delivers `didWriteData` to the
/// task-scoped delegate it takes (verified: zero callbacks for a 3 MB asset), and iterating
/// `bytes(from:)` a byte at a time runs at ~100 KB/s. So progress means a session-level
/// delegate, which in turn means bridging the callbacks back to async by hand.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URLResponse?, Error>?
    private var moveError: Error?

    /// A nil delegate queue gets a serial one, so the callbacks below never overlap.
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Resumes once the transfer ends, with the response for the caller to vet.
    func download(from url: URL) async throws -> URLResponse? {
        // The session holds a strong reference to its delegate — this object — until it is
        // invalidated, so this is what stops the download from leaking itself.
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return onProgress(nil) }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// The temporary file is deleted as soon as this returns, so claim it here.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let failure = error ?? moveError {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume(returning: task.response)
        }
    }
}

enum Log {
    static func info(_ message: String) {
        #if DEBUG
        print("[BeatSnap] \(message)")
        #endif
    }
}

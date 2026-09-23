import Darwin
import Foundation

enum CloudFileAccess {
    /// Older iCloud Drive versions enumerate hidden `.filename.ext.icloud` placeholders.
    /// Always expose the logical filename to playback, drag destinations, and the user.
    static func logicalURL(for enumeratedURL: URL) -> URL {
        let name = enumeratedURL.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return enumeratedURL }
        return enumeratedURL.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
    }

    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// Metadata and stat only. Checking availability must never hydrate a cloud file.
    static func needsDownload(at url: URL, values: URLResourceValues? = nil) -> Bool {
        let values = values ?? (try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]))
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded { return true }
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == nil { return true }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            // File Provider placeholders (including modern iCloud Drive) may have an ordinary
            // filename and report readable permissions despite having no local contents.
            return info.st_flags & UInt32(SF_DATALESS) != 0
        }
        return FileManager.default.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// File coordination waits for iCloud/File Provider materialization on a worker thread.
    /// The UI never blocks, and cancelling a request cancels the coordinated wait.
    static func materialize(_ url: URL) async throws -> URL {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var coordinationError: NSError?
            var result: Result<URL, Error> = .failure(CocoaError(.fileReadNoSuchFile))
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges,
                                   error: &coordinationError) { localURL in
                guard !needsDownload(at: localURL),
                      FileManager.default.isReadableFile(atPath: localURL.path) else {
                    result = .failure(CocoaError(.fileReadUnknown))
                    return
                }
                result = .success(localURL)
            }
            try Task.checkCancellation()
            if let coordinationError { throw coordinationError }
            return try result.get()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            coordinator.cancel()
        }
    }

    /// Coordinate deletion with the cloud provider without reading/downloading the audio.
    static func delete(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var deletionError: Error?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting,
                                   error: &coordinationError) { itemURL in
                do { try FileManager.default.removeItem(at: itemURL) }
                catch { deletionError = error }
            }
            if let coordinationError { throw coordinationError }
            if let deletionError { throw deletionError }
        }.value
    }
}

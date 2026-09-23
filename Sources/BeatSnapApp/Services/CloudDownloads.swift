import Foundation
import Observation

/// Progress belongs to one file, so a download does not invalidate every library row.
@MainActor @Observable
final class BeatDownload {
    var isDownloading = true
    var fraction: Double?
    var error: String?
}

@MainActor @Observable
final class CloudDownloads {
    private(set) var transfers: [String: BeatDownload] = [:]
    @ObservationIgnored private var tasks: [String: Task<URL, Error>] = [:]
    @ObservationIgnored private let materialize: @Sendable (URL) async throws -> URL

    init(materialize: @escaping @Sendable (URL) async throws -> URL = { try await CloudFileAccess.materialize($0) }) {
        self.materialize = materialize
    }

    /// Playback and any drag consumers share a single materialization request per file.
    func availableURL(for beat: Beat) async throws -> URL {
        if let task = tasks[beat.filePath] { return try await task.value }
        let transfer = BeatDownload()
        let isCloud = beat.needsDownload || CloudFileAccess.needsDownload(at: beat.fileURL)
        if isCloud { transfers[beat.filePath] = transfer }
        let materialize = self.materialize
        let task = Task { () throws -> URL in
            let progress = isCloud ? CloudDownloadProgress(url: beat.fileURL, transfer: transfer) : nil
            progress?.start()
            defer {
                progress?.stop()
                self.tasks[beat.filePath] = nil
                transfer.isDownloading = false
            }
            do {
                let url = try await materialize(beat.fileURL)
                try Task.checkCancellation()
                transfer.fraction = 1
                return url
            } catch {
                transfer.error = Task.isCancelled ? "Download cancelled." : error.localizedDescription
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        tasks[beat.filePath] = task
        return try await task.value
    }

    func cancel(_ beat: Beat) {
        tasks[beat.filePath]?.cancel()
    }

    func reconcile(_ beats: [Beat]) {
        let paths = Set(beats.map(\.filePath))
        for (path, transfer) in transfers where !transfer.isDownloading {
            if transfer.error == nil || !paths.contains(path) { transfers[path] = nil }
        }
    }
}

/// iCloud's percentage is metadata, not bytes read by BeatSnap. Some providers omit it;
/// those downloads deliberately keep an indeterminate indicator instead of a fake percent.
@MainActor
private final class CloudDownloadProgress {
    private let query = NSMetadataQuery()
    private let url: URL
    private let transfer: BeatDownload
    private var observers: [NSObjectProtocol] = []

    init(url: URL, transfer: BeatDownload) {
        self.url = url
        self.transfer = transfer
    }

    func start() {
        query.searchScopes = [url.deletingLastPathComponent()]
        query.searchItems = [url]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, url.lastPathComponent)
        query.notificationBatchingInterval = 0.25
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        query.start()
    }

    private func update() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        for case let item as NSMetadataItem in query.results {
            guard let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber,
                  percent.doubleValue.isFinite else { continue }
            transfer.fraction = min(1, max(0, percent.doubleValue / 100))
        }
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

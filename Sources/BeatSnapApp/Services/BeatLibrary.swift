import AppKit
import BeatSnapAnalysis
import Foundation
import Observation

/// Owns the library and drives the queue: download/copy → analyse → store.
///
/// Everything funnels through one serial queue so links and dropped files can be piled up in
/// any order and any quantity. The queue is driven by a single `Task` that outlives the
/// panel, which is what lets the app keep working while it's only a menubar icon.
@MainActor
@Observable
final class BeatLibrary {
    private(set) var beats: [Beat] = []
    /// Initial scan of the selected folder; background refreshes keep the list visible.
    private(set) var isLoadingFolder = true
    /// Pending, in-flight and failed items, oldest first.
    private(set) var queue: [QueueItem] = []
    var errorMessage: String?
    let downloads = CloudDownloads()

    /// URL waiting on a "this video is long" confirmation.
    var pendingLongVideo: (url: String, info: VideoInfo)?
    /// Text currently in the URL field.
    var urlText: String = ""
    var isCheckingLink = false
    /// True while an audio file is being dragged over the panel.
    var isDropTargeted = false

    /// Items still to be done — failed rows are just receipts and don't count.
    var pendingCount: Int { queue.filter { !$0.stage.isFailed }.count }

    private let store = BeatStore.shared
    private let analyzer = AppAudioAnalyzer()
    /// The single drain task, non-nil while the queue is being worked through.
    private var worker: Task<Void, Never>?

    @ObservationIgnored private var folderTimer: Timer?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanRevision = UUID()
    @ObservationIgnored private var folderEntries: [String: BeatFolderScanner.Entry] = [:]
    @ObservationIgnored private var displayedDirectory: URL?
    @ObservationIgnored private let folderMonitor = BeatFolderMonitor()

    init() {
        folderMonitor.onChange = { [weak self] in self?.refreshFolder() }
        refreshFolder()
        // A safety net for disconnected volumes, cloud providers, and in-place file writes
        // that do not change directory entries. Normal additions/removals use notifications.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scanTask == nil else { return }
                self.refreshFolder()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        folderTimer = timer
    }

    deinit {
        folderTimer?.invalidate()
        scanTask?.cancel()
    }

    /// Scan away from the UI actor. A newer refresh supersedes an older result, including
    /// scans started before an import, rename, deletion, or change of selected folder.
    func refreshFolder() {
        scanTask?.cancel()
        let revision = UUID()
        scanRevision = revision
        let directory = store.beatsDirectory().standardizedFileURL
        folderMonitor.watch(directory)
        if displayedDirectory != directory {
            isLoadingFolder = true
            beats = []
            folderEntries = [:]
            displayedDirectory = directory
        }
        let cached = folderEntries
        let known = beats
        scanTask = Task { [weak self] in
            let scan = Task.detached(priority: .utility) {
                Result { try BeatFolderScanner.scan(directory: directory, cached: cached, known: known) }
            }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard let self, !Task.isCancelled, self.scanRevision == revision else { return }
            self.scanTask = nil
            defer { self.isLoadingFolder = false }
            switch result {
            case .success(let entries):
                self.folderEntries = entries
                var current: [Beat] = entries.values.map { $0.beat }
                current.sort { (left: Beat, right: Beat) -> Bool in
                    if left.createdAt == right.createdAt { return left.filePath < right.filePath }
                    return left.createdAt > right.createdAt
                }
                if self.beats != current { self.beats = current }
                self.downloads.reconcile(current)
            case .failure(let error):
                self.folderEntries = [:]
                self.beats = []
                self.errorMessage = "Could not read the beats folder: \(error.localizedDescription)"
            }
        }
    }

    var subtitle: String {
        if pendingCount > 0 { return "\(pendingCount) in queue" }
        if isLoadingFolder { return "Scanning beats folder…" }
        if beats.isEmpty { return "Paste a link or drop a file" }
        return "\(beats.count) beat\(beats.count == 1 ? "" : "s")"
    }

    // MARK: - Adding work

    /// Metadata is fetched up front even while the queue is running: the title, the duplicate
    /// check and the "longer than 10 minutes" question all belong to the moment the user hits
    /// Download, not to whenever the item reaches the front of the queue.
    func submitCurrentURL() async {
        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !isCheckingLink else { return }

        errorMessage = nil
        isCheckingLink = true
        defer { isCheckingLink = false }

        do {
            let info = try await YouTubeDownloader.fetchInfo(url: link)
            if let duplicate = duplicateMessage(videoID: info.id) {
                errorMessage = duplicate
                return
            }
            // Long videos are usually full mixes, not beats — confirm first.
            if info.durationSec > 600 {
                pendingLongVideo = (link, info)
                return
            }
            urlText = ""
            enqueue(QueueItem(title: info.title, source: .youtube(url: link, info: info)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmPendingLongVideo() {
        guard let pending = pendingLongVideo else { return }
        pendingLongVideo = nil
        urlText = ""
        enqueue(QueueItem(title: pending.info.title, source: .youtube(url: pending.url, info: pending.info)))
    }

    /// Queue audio files dropped onto the panel, in the order they were dropped.
    func importDroppedFiles(_ urls: [URL]) {
        errorMessage = nil
        var duplicates = 0
        for url in urls {
            // Re-dropping a beat that's already indexed (straight out of the beats folder)
            // would otherwise pile up copies with doubled BPM/key suffixes.
            guard !isKnown(fileURL: url) else {
                duplicates += 1
                continue
            }
            enqueue(
                QueueItem(title: url.deletingPathExtension().lastPathComponent, source: .file(url))
            )
        }
        if duplicates > 0 {
            errorMessage = duplicates == 1
                ? "That file is already in your library."
                : "\(duplicates) of those files are already in your library."
        }
    }

    /// Already downloaded, or already waiting to be.
    func isKnown(videoID: String) -> Bool {
        beats.contains { $0.youtubeId == videoID } || queue.contains { $0.videoID == videoID }
    }

    private func isKnown(fileURL url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return beats.contains { $0.filePath == path }
            || queue.contains { $0.fileURL?.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    private func duplicateMessage(videoID: String) -> String? {
        if let existing = beats.first(where: { $0.youtubeId == videoID }) {
            return "Already in your library: \(existing.title)"
        }
        if let queued = queue.first(where: { $0.videoID == videoID }) {
            return "Already in the queue: \(queued.title)"
        }
        return nil
    }

    /// Forget a queued or failed item. Never offered for the item being worked on.
    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    // MARK: - Queue

    private func enqueue(_ item: QueueItem) {
        queue.append(item)
        // A drain already in flight will pick this up on its next pass; no second worker.
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    /// One item at a time, oldest first. Failed items stay in the list as their own error
    /// message and are stepped over rather than retried.
    private func drain() async {
        while let next = queue.first(where: { !$0.stage.isFailed }) {
            switch next.source {
            case .youtube(let url, let info): await download(next.id, url: url, info: info)
            case .file(let url): await importFile(next.id, url: url)
            }
            if let index = queue.firstIndex(where: { $0.id == next.id }), !queue[index].stage.isFailed {
                queue.remove(at: index)
            }
        }
        // Safe to clear: nothing can be appended between the loop test and here without the
        // whole method being suspended, and every mutation happens on the main actor.
        worker = nil
    }

    private func setStage(_ stage: QueueStage, for id: QueueItem.ID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].stage = stage
    }

    private func download(_ id: QueueItem.ID, url: String, info: VideoInfo) async {
        setStage(.starting, for: id)

        do {
            let directory = store.beatsDirectory()

            let downloaded = try await YouTubeDownloader.downloadWAV(
                url: url,
                into: directory,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.setStage(.downloading(progress: progress), for: id) }
                },
                onConverting: { [weak self] in
                    Task { @MainActor in self?.setStage(.converting, for: id) }
                }
            )

            setStage(.analyzing, for: id)
            let analysis = try await analyze(url: downloaded)

            setStage(.saving, for: id)
            let baseName = "\(BeatStore.sanitize(filename: info.title)) [\(analysis.bpm)BPM \(analysis.keyShort)]"
            let finalURL = BeatStore.uniqueURL(in: directory, baseName: baseName, extension: "wav")
            try FileManager.default.moveItem(at: downloaded, to: finalURL)

            record(
                Beat(
                    id: Beat.makeID(),
                    title: info.title,
                    fileName: finalURL.lastPathComponent,
                    filePath: finalURL.path,
                    bpm: analysis.bpm,
                    key: analysis.key,
                    durationSec: info.durationSec,
                    createdAt: Date().timeIntervalSince1970 * 1000,
                    youtubeId: info.id
                )
            )
        } catch {
            setStage(.failed(error.localizedDescription), for: id)
        }
    }

    /// Dropped files are copied, not moved: they still belong to the user wherever they keep
    /// them. A file that's *already* in the beats folder is the exception — there it is just
    /// renamed, since a copy alongside it would be the same audio twice.
    ///
    /// The format is kept as-is; re-encoding an MP3 to WAV would only inflate it.
    private func importFile(_ id: QueueItem.ID, url: URL) async {
        setStage(.analyzing, for: id)
        let title = BeatStore.stripAnalysisTag(from: url.deletingPathExtension().lastPathComponent)

        do {
            let analysis = try await analyze(url: url)

            setStage(.saving, for: id)
            let directory = store.beatsDirectory()
            let baseName = "\(BeatStore.sanitize(filename: title)) [\(analysis.bpm)BPM \(analysis.keyShort)]"
            let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension.lowercased()
            let finalURL: URL

            if store.isInBeatsDirectory(url) {
                if url.lastPathComponent == "\(baseName).\(ext)" {
                    // Already sitting there under the name it would be given: nothing to do
                    // on disk, just index it.
                    finalURL = url
                } else {
                    finalURL = BeatStore.uniqueURL(in: directory, baseName: baseName, extension: ext)
                    try FileManager.default.moveItem(at: url, to: finalURL)
                }
            } else {
                finalURL = BeatStore.uniqueURL(in: directory, baseName: baseName, extension: ext)
                try FileManager.default.copyItem(at: url, to: finalURL)
            }

            record(
                Beat(
                    id: Beat.makeID(),
                    title: title,
                    fileName: finalURL.lastPathComponent,
                    filePath: finalURL.path,
                    bpm: analysis.bpm,
                    key: analysis.key,
                    durationSec: Int((AudioDecoder.duration(of: finalURL) ?? 0).rounded()),
                    createdAt: Date().timeIntervalSince1970 * 1000,
                    youtubeId: nil
                )
            )
        } catch {
            setStage(.failed(error.localizedDescription), for: id)
        }
    }

    private func record(_ beat: Beat) {
        if store.isInBeatsDirectory(beat.fileURL) {
            beats.removeAll { $0.filePath == beat.filePath }
            beats.insert(beat, at: 0)
        }
        refreshFolder()
    }

    /// The preference is captured when analysis starts. Apple's analyzer manages its own
    /// asynchronous work; the custom DSP path moves its CPU work off the main actor.
    private func analyze(url: URL) async throws -> AnalysisResult {
        let analyzer = self.analyzer
        let algorithm = AppSettings.shared.analysisAlgorithm
        return try await analyzer.analyze(url: url, preferred: algorithm)
    }

    // MARK: - Library actions

    func availableURL(for beat: Beat) async throws -> URL {
        do {
            let url = try await downloads.availableURL(for: beat)
            if let index = beats.firstIndex(where: { $0.id == beat.id }) {
                beats[index].needsDownload = false
            }
            refreshFolder()
            return url
        } catch {
            if !(error is CancellationError) {
                errorMessage = "Could not download \(beat.title): \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// Run the selected analyzer again without changing the file or library metadata.
    /// The result remains a draft in the editor until the user explicitly saves it.
    func reanalyzeLabels(for beat: Beat) async throws -> BeatLabelAnalysis {
        guard let current = beats.first(where: { $0.id == beat.id }) else {
            throw LabelUpdateError.beatNotFound
        }
        let url = try await availableURL(for: current)
        try Task.checkCancellation()
        let result = try await analyze(url: url)
        guard let key = BeatKey(displayName: result.key) else {
            throw LabelUpdateError.unsupportedKey(result.key)
        }
        return BeatLabelAnalysis(bpm: result.bpm, key: key)
    }

    /// Correct the labels attached to an analyzed beat. This only renames the file and
    /// refreshes the folder listing; no audio samples are decoded or changed.
    func updateLabels(for beat: Beat, bpm: Int, key: BeatKey) throws {
        guard (1...999).contains(bpm) else {
            throw LabelUpdateError.invalidBPM
        }
        guard let index = beats.firstIndex(where: { $0.id == beat.id }) else {
            throw LabelUpdateError.beatNotFound
        }

        let current = beats[index]
        let oldURL = current.fileURL
        guard FileManager.default.fileExists(atPath: oldURL.path) else {
            throw LabelUpdateError.fileMissing
        }

        let ext = oldURL.pathExtension.isEmpty ? "wav" : oldURL.pathExtension
        let baseName = "\(BeatStore.sanitize(filename: current.title)) [\(bpm)BPM \(key.filenameName)]"
        let exactURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent("\(baseName).\(ext)")
        let newURL = oldURL.standardizedFileURL == exactURL.standardizedFileURL
            ? oldURL
            : BeatStore.uniqueURL(
                in: oldURL.deletingLastPathComponent(),
                baseName: baseName,
                extension: ext
            )

        let didRename = newURL != oldURL
        if didRename {
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                throw LabelUpdateError.renameFailed(error)
            }
        }

        var updated = current
        updated.bpm = bpm
        updated.key = key.displayName
        updated.fileName = newURL.lastPathComponent
        updated.filePath = newURL.path

        beats[index] = updated
        refreshFolder()
    }

    func delete(_ beat: Beat) {
        Task {
            do {
                try await CloudFileAccess.delete(beat.fileURL)
                beats.removeAll { $0.id == beat.id }
            } catch {
                errorMessage = "Could not delete the beat: \(error.localizedDescription)"
            }
            refreshFolder()
        }
    }

    func revealInFinder(_ beat: Beat) {
        NSWorkspace.shared.activateFileViewerSelecting([beat.fileURL])
    }

    func openBeatsFolder() {
        NSWorkspace.shared.open(store.beatsDirectory())
    }

    func chooseDownloadFolder() {
        // The app is an accessory (no Dock icon) and its window floats, so bring it
        // forward first or the modal picker can open behind everything.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.level = .modalPanel
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the beats folder to display and save new beats in"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.shared.downloadDirectory = url
            refreshFolder()
        }
    }

    func resetDownloadFolder() {
        AppSettings.shared.downloadDirectory = nil
        refreshFolder()
    }

    var downloadFolderPath: String {
        store.beatsDirectory().path
    }

    var usingCustomFolder: Bool {
        AppSettings.shared.downloadDirectory != nil
    }
}

private enum LabelUpdateError: LocalizedError {
    case invalidBPM
    case beatNotFound
    case fileMissing
    case unsupportedKey(String)
    case renameFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidBPM:
            "Enter a BPM between 1 and 999."
        case .beatNotFound:
            "This beat is no longer in the library."
        case .fileMissing:
            "The audio file could not be found."
        case .unsupportedKey(let key):
            "The analyzer returned an unsupported key: \(key)."
        case .renameFailed(let error):
            "The audio file could not be renamed: \(error.localizedDescription)"
        }
    }
}

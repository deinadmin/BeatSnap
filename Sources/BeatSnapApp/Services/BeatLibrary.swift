import AppKit
import BeatSnapAnalysis
import Foundation
import Observation

/// Owns the library and drives download → convert → analyse → store.
@MainActor
@Observable
final class BeatLibrary {
    private(set) var beats: [Beat] = []
    private(set) var job: DownloadJob?
    var errorMessage: String?

    /// URL waiting on a "this video is long" confirmation.
    var pendingLongVideo: (url: String, info: VideoInfo)?
    /// Text currently in the URL field.
    var urlText: String = ""
    var isCheckingLink = false
    /// True while an audio file is being dragged over the panel.
    var isDropTargeted = false

    var isBusy: Bool { job != nil || isCheckingLink }

    private let store = BeatStore.shared
    private let analyzer = BeatAnalyzer()

    init() {
        beats = store.load()
    }

    var subtitle: String {
        if beats.isEmpty { return "Paste a link or drop a file" }
        return "\(beats.count) beat\(beats.count == 1 ? "" : "s")"
    }

    // MARK: - Download pipeline

    func submitCurrentURL() async {
        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !isBusy else { return }

        errorMessage = nil
        isCheckingLink = true
        defer { isCheckingLink = false }

        do {
            let info = try await YouTubeDownloader.fetchInfo(url: link)
            if let existing = beats.first(where: { $0.youtubeId == info.id }) {
                errorMessage = "Already in your library: \(existing.title)"
                return
            }
            // Long videos are usually full mixes, not beats — confirm first.
            if info.durationSec > 600 {
                pendingLongVideo = (link, info)
                return
            }
            urlText = ""
            await runPipeline(url: link, info: info)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmPendingLongVideo() async {
        guard let pending = pendingLongVideo else { return }
        pendingLongVideo = nil
        urlText = ""
        await runPipeline(url: pending.url, info: pending.info)
    }

    /// Download a URL that arrived from the clipboard when the window was summoned.
    func autoDownload(url: String) async {
        guard !isBusy else { return }
        urlText = url
        await submitCurrentURL()
    }

    private func runPipeline(url: String, info: VideoInfo) async {
        job = DownloadJob(title: info.title, stage: .starting)
        defer { job = nil }

        do {
            let directory = store.beatsDirectory()

            let downloaded = try await YouTubeDownloader.downloadWAV(
                url: url,
                into: directory,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.job?.stage = .downloading(progress: progress) }
                },
                onConverting: { [weak self] in
                    Task { @MainActor in self?.job?.stage = .converting }
                }
            )

            job?.stage = .analyzing
            let analysis = try await analyze(url: downloaded)

            job?.stage = .saving
            let baseName = "\(BeatStore.sanitize(filename: info.title)) [\(analysis.bpm)BPM \(analysis.keyShort)]"
            let finalURL = BeatStore.uniqueURL(in: directory, baseName: baseName, extension: "wav")
            try FileManager.default.moveItem(at: downloaded, to: finalURL)

            let beat = Beat(
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
            beats.insert(beat, at: 0)
            store.save(beats)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Local file import

    /// Take audio files dropped onto the panel through the same analyse → name → store
    /// steps a download gets. Files are copied, not moved: they still belong to the user
    /// wherever they keep them.
    func importDroppedFiles(_ urls: [URL]) async {
        guard !isBusy else {
            errorMessage = "One at a time — wait for the beat in progress to finish."
            return
        }
        errorMessage = nil
        for url in urls { await importFile(at: url) }
    }

    private func importFile(at url: URL) async {
        let title = url.deletingPathExtension().lastPathComponent
        job = DownloadJob(title: title, stage: .analyzing)
        defer { job = nil }

        do {
            let analysis = try await analyze(url: url)

            job?.stage = .saving
            let directory = store.beatsDirectory()
            let baseName = "\(BeatStore.sanitize(filename: title)) [\(analysis.bpm)BPM \(analysis.keyShort)]"
            // Keep the source format: re-encoding an MP3 to WAV would only inflate it.
            let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension.lowercased()
            let finalURL = BeatStore.uniqueURL(in: directory, baseName: baseName, extension: ext)
            try FileManager.default.copyItem(at: url, to: finalURL)

            let beat = Beat(
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
            beats.insert(beat, at: 0)
            store.save(beats)
        } catch {
            errorMessage = "Couldn't import \(title): \(error.localizedDescription)"
        }
    }

    /// Analysis is CPU-bound; keep it off the main actor.
    private func analyze(url: URL) async throws -> AnalysisResult {
        let analyzer = self.analyzer
        return try await Task.detached(priority: .userInitiated) {
            try analyzer.analyze(url: url)
        }.value
    }

    // MARK: - Library actions

    func delete(_ beat: Beat) {
        try? FileManager.default.removeItem(at: beat.fileURL)
        beats.removeAll { $0.id == beat.id }
        store.save(beats)
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
        panel.message = "Choose where downloaded beats are saved"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.shared.downloadDirectory = url
        }
    }

    func resetDownloadFolder() {
        AppSettings.shared.downloadDirectory = nil
    }

    var downloadFolderPath: String {
        store.beatsDirectory().path
    }

    var usingCustomFolder: Bool {
        AppSettings.shared.downloadDirectory != nil
    }
}

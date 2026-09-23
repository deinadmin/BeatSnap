import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BeatSnapApp

struct CloudDownloadsTests {
    private func cloudBeat() -> Beat {
        Beat(id: "cloud", title: "Cloud", fileName: "Cloud [82BPM Emin].wav",
             filePath: "/tmp/Cloud [82BPM Emin].wav", bpm: 82, key: "E minor",
             durationSec: 0, createdAt: 0, needsDownload: true)
    }

    @Test @MainActor func concurrentConsumersShareOneDownload() async throws {
        let gate = DownloadGate()
        let downloads = CloudDownloads { try await gate.load($0) }
        let beat = cloudBeat()
        let playback = Task { try await downloads.availableURL(for: beat) }
        let drag = Task { try await downloads.availableURL(for: beat) }
        await gate.waitForRequest()
        #expect(downloads.transfers[beat.filePath]?.isDownloading == true)
        await gate.finish()
        #expect(try await playback.value == beat.fileURL)
        #expect(try await drag.value == beat.fileURL)
        #expect(await gate.requests == 1)
        #expect(downloads.transfers[beat.filePath]?.isDownloading == false)
    }

    @Test @MainActor func failuresCanBeRetried() async throws {
        let attempts = DownloadAttempts()
        let downloads = CloudDownloads { try await attempts.load($0) }
        let beat = cloudBeat()
        await #expect(throws: CocoaError.self) { try await downloads.availableURL(for: beat) }
        #expect(downloads.transfers[beat.filePath]?.error != nil)
        #expect(try await downloads.availableURL(for: beat) == beat.fileURL)
        #expect(downloads.transfers[beat.filePath]?.error == nil)
        #expect(await attempts.count == 2)
    }

    @Test @MainActor func cancellationReleasesWaitingConsumers() async throws {
        let downloads = CloudDownloads { url in
            try await Task.sleep(for: .seconds(60))
            return url
        }
        let beat = cloudBeat()
        let request = Task { try await downloads.availableURL(for: beat) }
        while downloads.transfers[beat.filePath] == nil { await Task.yield() }
        downloads.cancel(beat)
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(downloads.transfers[beat.filePath]?.isDownloading == false)
        #expect(downloads.transfers[beat.filePath]?.error == "Download cancelled.")
    }

    @Test func dragFileURLWaitsForMaterialization() async throws {
        let gate = DownloadGate()
        let beat = cloudBeat()
        let provider = BeatDragProvider.deferred(for: beat) { try await gate.load(beat.fileURL) }
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.wav.identifier))
        #expect(await gate.requests == 0)
        let request = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
        }
        await gate.waitForRequest()
        await gate.finish()
        let data = try await request.value
        let url = try #require(URL(dataRepresentation: data, relativeTo: nil))
        #expect(url == beat.fileURL)
        #expect(!url.lastPathComponent.hasSuffix(".icloud"))
    }

    @Test func missingFileFailsInsteadOfReturningAnUnavailableURL() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: (any Error).self) { try await CloudFileAccess.materialize(url) }
    }

    @Test func coordinatedLocalAccessAndDeletion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("local contents".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let local = try await CloudFileAccess.materialize(url)
        #expect(try Data(contentsOf: local) == Data("local contents".utf8))
        try await CloudFileAccess.delete(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private actor DownloadGate {
    private(set) var requests = 0
    private var pending: [(URL, CheckedContinuation<URL, Error>)] = []
    private var released = false

    func load(_ url: URL) async throws -> URL {
        requests += 1
        if released { return url }
        return try await withCheckedThrowingContinuation { pending.append((url, $0)) }
    }

    func waitForRequest() async {
        while requests == 0 { await Task.yield() }
    }

    func finish() {
        released = true
        pending.forEach { $0.1.resume(returning: $0.0) }
        pending = []
    }
}

private actor DownloadAttempts {
    private(set) var count = 0
    func load(_ url: URL) throws -> URL {
        count += 1
        if count == 1 { throw CocoaError(.fileReadUnknown) }
        return url
    }
}

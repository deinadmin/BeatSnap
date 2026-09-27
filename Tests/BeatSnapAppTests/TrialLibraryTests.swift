import Foundation
import Testing
@testable import BeatSnapApp

@MainActor
struct TrialLibraryTests {
    @Test func trialFolderLimitQueueReservationsAndUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Cloud placeholders exercise tagged folder loading without invoking the analyzer.
        for index in 0..<13 {
            let url = CloudFileAccess.placeholderURL(for:
                directory.appendingPathComponent("Beat\(index) [140BPM Amin].wav"))
            try Data("placeholder".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))], ofItemAtPath: url.path)
        }
        let incoming = directory.appendingPathComponent("incoming.wav")
        var trial = true
        let library = BeatLibrary(store: BeatStore(directoryOverride: directory))
        library.canUseLibrary = { true }
        library.isTrialMode = { trial }
        // A paste delivered before the initial scan must be canceled before analysis.
        library.importDroppedFiles([incoming])
        try await wait { !library.isLoadingFolder && library.pendingCount == 0 }
        #expect(library.queue.isEmpty)
        #expect(library.beats.count == 10)
        #expect(library.trialPreviewBeats.map(\.title) == ["Beat2", "Beat1", "Beat0"])
        #expect(library.beats.first?.title == "Beat12")
        #expect(!library.beats.contains { $0.title == "Beat0" || $0.title == "Beat1" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 13)
        library.importDroppedFiles([incoming])
        #expect(library.queue.isEmpty)
        #expect(library.toasts.items.last?.title == "BeatSnap is in Trial Mode")
        #expect(library.toasts.items.last?.message == "Provide a full license to have more than 10 beats in your library.")
        library.urlText = "https://example.com/beat.wav"
        await library.submitCurrentURL()
        #expect(library.queue.isEmpty)
        #expect(library.urlText == "https://example.com/beat.wav")
        trial = false
        library.licenseAccessChanged(true)
        try await wait { library.beats.count == 13 }
        #expect(library.trialPreviewBeats.isEmpty)
        trial = true
        library.licenseAccessChanged(true)
        #expect(library.beats.count == 10)
        // Removing files frees capacity; successful queued work reserves the last slot.
        for index in 0..<4 {
            try FileManager.default.removeItem(at: CloudFileAccess.placeholderURL(for:
                directory.appendingPathComponent("Beat\(index) [140BPM Amin].wav")))
        }
        library.refreshFolder()
        try await wait { library.beats.count == 9 }
        #expect(library.trialPreviewBeats.isEmpty)
        library.importDroppedFiles([incoming, directory.appendingPathComponent("second.wav")])
        #expect(library.pendingCount == 1)
        #expect(library.toasts.items.last?.title == "BeatSnap is in Trial Mode")
        // A failed import releases its reservation, and its receipt does not consume a slot.
        try await wait { library.pendingCount == 0 }
        library.importDroppedFiles([directory.appendingPathComponent("second.wav")])
        #expect(library.pendingCount == 1)
        try await wait { library.pendingCount == 0 }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

import AVFoundation
import Foundation
import Testing
@testable import BeatSnapApp

@MainActor
struct BeatRenameTests {
    @Test func renameKeepsBPMAndKeyTag() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["downloadDirectoryPath"] = directory.path
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let original = directory.appendingPathComponent("Old Name [140BPM F#min].wav")
        try writeAudio(original)
        try writeAudio(directory.appendingPathComponent("Taken [140BPM F#min].wav"))
        let placeholder = CloudFileAccess.placeholderURL(
            for: directory.appendingPathComponent("Cloud Beat [82BPM Emin].wav")
        )
        try Data("placeholder".utf8).write(to: placeholder)

        let library = BeatLibrary()
        let beat = try await waitForBeat(in: library, title: "Old Name")
        try library.rename(beat, to: "  New Name [99BPM Cmaj]  ")
        let renamed = try #require(library.beats.first { $0.id == beat.id })
        #expect(renamed.title == "New Name")
        #expect(renamed.bpm == 140)
        #expect(renamed.key == "F# minor")
        #expect(renamed.fileName == "New Name [140BPM F#min].wav")
        #expect(FileManager.default.fileExists(atPath: renamed.filePath))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(library.toasts.items.last?.title == "Beat renamed")

        let toastCount = library.toasts.items.count
        try library.rename(renamed, to: "New Name")
        #expect(library.toasts.items.count == toastCount)
        #expect(FileManager.default.fileExists(atPath: renamed.filePath))

        try library.rename(renamed, to: "Taken")
        let collided = try #require(library.beats.first { $0.id == beat.id })
        #expect(collided.title == "Taken")
        #expect(collided.fileName == "Taken [140BPM F#min] (2).wav")
        #expect(collided.bpm == 140)
        #expect(collided.key == "F# minor")

        do {
            try library.rename(collided, to: "   [140BPM Amin]  ")
            Issue.record("A blank title should be rejected")
        } catch {
            #expect(error.localizedDescription == "Enter a name for this beat.")
        }
        #expect(FileManager.default.fileExists(atPath: collided.filePath))

        let cloud = try await waitForBeat(in: library, title: "Cloud Beat")
        try library.rename(cloud, to: "Renamed Cloud")
        let renamedCloud = try #require(library.beats.first { $0.id == cloud.id })
        #expect(renamedCloud.title == "Renamed Cloud")
        #expect(renamedCloud.fileName == "Renamed Cloud [82BPM Emin].wav")
        #expect(renamedCloud.bpm == 82)
        #expect(renamedCloud.key == "E minor")
        #expect(FileManager.default.fileExists(
            atPath: CloudFileAccess.placeholderURL(for: renamedCloud.fileURL).path
        ))
        #expect(!FileManager.default.fileExists(atPath: placeholder.path))
    }

    private func waitForBeat(in library: BeatLibrary, title: String) async throws -> Beat {
        for _ in 0..<100 {
            if let beat = library.beats.first(where: { $0.title == title }) { return beat }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for \(title)")
        return try #require(library.beats.first { $0.title == title })
    }

    private func writeAudio(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        buffer.floatChannelData![0].update(repeating: 0, count: 8000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

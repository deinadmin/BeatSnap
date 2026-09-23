import AVFoundation
import Foundation
import Testing
@testable import BeatSnapApp

struct BeatFolderScannerTests {
    @Test func filenameLabels() {
        let labels = BeatFolderScanner.labels(in: "Beat [82BPM Emin]")
        #expect(labels?.title == "Beat")
        #expect(labels?.bpm == 82)
        #expect(labels?.key == "E minor")
        #expect(BeatFolderScanner.labels(in: "Beat [140BPM F#maj] (2)")?.key == "F# major")
        #expect(BeatFolderScanner.labels(in: "Beat [90BPM Bbmin]")?.key == "Bb minor")
        for name in ["Beat (2021)", "Beat(148Bpm)", "Beat [0BPM Emin]",
                     "Beat [82BPM Emin] extra", "Beat [82BPM Hmin]"] {
            #expect(BeatFolderScanner.labels(in: name) == nil)
        }
    }

    @Test func directoryIsAuthoritative() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Beat [82BPM Emin].wav")
        try writeAudio(original)
        try writeAudio(directory.appendingPathComponent("Untagged.wav"))
        try Data("broken".utf8).write(to: directory.appendingPathComponent("Broken [90BPM Amaj].wav"))
        try Data("text".utf8).write(to: directory.appendingPathComponent("Text [90BPM Amaj].txt"))
        let nested = directory.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeAudio(nested.appendingPathComponent("Nested [82BPM Emin].wav"))

        let first = try BeatFolderScanner.scan(directory: directory, cached: [:], known: [])
        #expect(first.count == 1)
        let beat = try #require(first[original.path]?.beat, "Expected \(original.path); found \(Array(first.keys))")
        #expect(beat.durationSec == 1)
        let unchanged = try BeatFolderScanner.scan(directory: directory, cached: first, known: [beat])
        #expect(unchanged[original.path]?.beat == beat)

        let renamed = directory.appendingPathComponent("Renamed [120BPM Cmaj] (2).wav")
        try FileManager.default.moveItem(at: original, to: renamed)
        let second = try BeatFolderScanner.scan(directory: directory, cached: first, known: [beat])
        #expect(second.count == 1)
        #expect(second[original.path] == nil)
        #expect(second[renamed.path]?.beat.bpm == 120)
        #expect(second[renamed.path]?.beat.title == "Renamed")
        // Changing folders never carries entries from the previous directory into the list.
        let other = try BeatFolderScanner.scan(directory: nested, cached: second, known: [beat])
        #expect(other.count == 1)
        #expect(other[renamed.path] == nil)

        try FileManager.default.removeItem(at: renamed)
        #expect(try BeatFolderScanner.scan(directory: directory, cached: second, known: [beat]).isEmpty)
    }

    private func writeAudio(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        buffer.floatChannelData![0].update(repeating: 0, count: 8000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @Test func cloudPlaceholdersStayVisibleWithoutReadingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logicalURL = directory.appendingPathComponent("Cloud Beat [82BPM Emin].wav")
        let placeholder = CloudFileAccess.placeholderURL(for: logicalURL)
        // Deliberately not valid audio: enumerating a placeholder must never decode it.
        try Data("placeholder metadata".utf8).write(to: placeholder)
        try Data().write(to: directory.appendingPathComponent(".Untagged.wav.icloud"))
        try Data().write(to: directory.appendingPathComponent(".Text [80BPM Cmaj].txt.icloud"))
        let cloud = try BeatFolderScanner.scan(directory: directory, cached: [:], known: [])
        let beat = try #require(cloud.values.first?.beat)
        #expect(cloud.count == 1)
        #expect(beat.needsDownload)
        #expect(beat.fileName == logicalURL.lastPathComponent)
        #expect(beat.title == "Cloud Beat")
        #expect(beat.bpm == 82)
        #expect(beat.key == "E minor")
        #expect(!FileManager.default.fileExists(atPath: logicalURL.path))

        try writeAudio(logicalURL)
        try FileManager.default.removeItem(at: placeholder)
        let local = try BeatFolderScanner.scan(directory: directory, cached: cloud, known: [beat])
        let downloaded = try #require(local.values.first?.beat)
        #expect(downloaded.id == beat.id)
        #expect(!downloaded.needsDownload)
        #expect(downloaded.durationSec == 1)

        try FileManager.default.removeItem(at: logicalURL)
        try Data().write(to: placeholder)
        let evicted = try BeatFolderScanner.scan(directory: directory, cached: local, known: [downloaded])
        #expect(evicted.values.first?.beat.id == beat.id)
        #expect(evicted.values.first?.beat.needsDownload == true)
        #expect(evicted.values.first?.beat.durationSec == 1)
        try FileManager.default.removeItem(at: placeholder)
        #expect(try BeatFolderScanner.scan(directory: directory, cached: evicted, known: [beat]).isEmpty)
    }

    @Test @MainActor func notificationsFollowSelectedFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let other = directory.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = BeatFolderMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.watch(directory)
        let file = directory.appendingPathComponent("Beat [82BPM Emin].wav")
        try writeAudio(file)
        for _ in 0..<100 where changes == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes == 1)
        try FileManager.default.removeItem(at: file)
        for _ in 0..<100 where changes < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes == 2)

        monitor.watch(other)
        try writeAudio(file)
        try await Task.sleep(for: .milliseconds(600))
        #expect(changes == 2)
        try writeAudio(other.appendingPathComponent("Other [90BPM Cmaj].wav"))
        for _ in 0..<100 where changes < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes == 3)
    }
}

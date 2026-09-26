import AppKit
import AVFoundation
import Foundation
import Testing
@testable import BeatSnapApp

@MainActor
struct AudioPasteHandlerTests {
    @Test func mixedFinderSelectionImportsOnlyAudio() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("Beat.wav")
        let text = directory.appendingPathComponent("Notes.txt")
        let folder = directory.appendingPathComponent("Folder.wav")
        try Data().write(to: audio)
        try Data().write(to: text)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([audio as NSURL, text as NSURL, folder as NSURL])

        let handler = AudioPasteHandler()
        var imported: [URL] = []
        handler.onPaste = { imported = $0 }
        #expect(handler.paste(from: pasteboard))
        #expect(imported == [audio])
    }

    @Test func plainTextKeepsNativePasteAndNonAudioFilesAreRejected() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let handler = AudioPasteHandler()
        var rejected = false
        handler.onRejectedFiles = { rejected = true }
        pasteboard.setString("https://example.com/beat.mp3", forType: .string)
        #expect(!handler.paste(from: pasteboard))
        #expect(!rejected)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Notes.txt")
        try Data("notes".utf8).write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        #expect(handler.paste(from: pasteboard))
        #expect(rejected)
    }

    @Test func onlyCommandVIsIntercepted() throws {
        for flags: NSEvent.ModifierFlags in [.command, [.command, .capsLock], [], .control,
                                            [.command, .shift], [.command, .option]] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            #expect(AudioPasteHandler.isPasteShortcut(event) == (flags == .command || flags == [.command, .capsLock]))
        }
    }

    @Test func pastedAudioIsCopiedAnalyzedAndSupportsTagAndDeleteToasts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("beats")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Pasted Beat.wav")
        try writeAudio(source)
        let originalBytes = try Data(contentsOf: source)

        // Use the argument domain, never the user's persisted folder or analyzer preference.
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["downloadDirectoryPath"] = destination.path
        arguments["analysisAlgorithm"] = "beatSnapDSP"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let library = BeatLibrary()
        // Unlicensed imports and submissions must never enter the queue.
        library.importDroppedFiles([source])
        library.urlText = "https://example.com/beat.wav"
        await library.submitCurrentURL()
        #expect(library.queue.isEmpty)
        library.urlText = ""
        library.canUseLibrary = { true }
        while library.isLoadingFolder { try await Task.sleep(for: .milliseconds(10)) }
        let handler = AudioPasteHandler()
        handler.onPaste = { library.importDroppedFiles($0) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([source as NSURL])
        #expect(handler.paste(from: pasteboard))
        while library.pendingCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(library.queue.isEmpty)
        let beat = try #require(library.beats.first)
        #expect(beat.bpm > 0)
        #expect(!beat.key.isEmpty)
        #expect(beat.fileURL.deletingLastPathComponent().resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: beat.fileURL) == originalBytes)
        #expect(try Data(contentsOf: source) == originalBytes)

        try library.updateLabels(for: beat, bpm: 123, key: BeatKey(tonic: "C", mode: .major))
        #expect(library.toasts.items.last?.kind == .success)
        #expect(library.toasts.items.last?.title == "Tags updated")
        let updated = try #require(library.beats.first)
        #expect(updated.fileName.contains("[123BPM Cmaj]"))
        library.delete(updated)
        while library.beats.contains(where: { $0.id == updated.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(library.toasts.items.last?.kind == .info)
        #expect(library.toasts.items.last?.title == "Beat deleted")
        #expect(!FileManager.default.fileExists(atPath: updated.filePath))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeAudio(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let count: AVAudioFrameCount = 44100 * 4
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for index in 0..<Int(count) {
            let time = Double(index) / 44100
            let pulse = exp(-time.truncatingRemainder(dividingBy: 0.5) * 25)
            buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 440 * time) * pulse * 0.6)
        }
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
    }
}

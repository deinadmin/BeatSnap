import AppKit

/// Finder publishes real file URLs alongside display text. Prefer those URLs so a file's
/// name never gets pasted into the download field. Ordinary text keeps its native behavior.
@MainActor
final class AudioPasteHandler {
    var canImport: () -> Bool = { true }
    var onPaste: (([URL]) -> Void)?
    var onRejectedFiles: (() -> Void)?

    static func containsFiles(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }

    @discardableResult
    func paste(from pasteboard: NSPasteboard) -> Bool {
        guard Self.containsFiles(on: pasteboard) else { return false }
        guard canImport() else { return true }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let audio = urls.filter(\.isAudioFile)
        if audio.isEmpty { onRejectedFiles?() } else { onPaste?(audio) }
        return true
    }

    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }
}

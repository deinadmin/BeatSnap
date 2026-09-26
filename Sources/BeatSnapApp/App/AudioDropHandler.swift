import AppKit
import UniformTypeIdentifiers

/// Dragging-destination logic for the panel: accept external drags that carry audio files
/// and ignore everything else.
///
/// Split out of `BeatPanel` because AppKit resolves a drag by hit-testing and then walking
/// *up* from the deepest view until something registered accepts it. The SwiftUI hosting
/// view sits on top and declines, so both its superview and the window itself register and
/// forward here — that covers every path the search can take without a transparent NSView
/// over the content, which would swallow clicks meant for SwiftUI.
@MainActor
final class AudioDropHandler {
    var canImport: () -> Bool = { true }
    var onTargetChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    private var isTargeted = false

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        setTargeted(true)
        return .copy
    }

    /// AppKit only reuses the `draggingEntered` operation if this isn't implemented at all,
    /// and the destination is asked again on every mouse move, so answer consistently.
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    func draggingEnded() { setTargeted(false) }

    func performDrag(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard accepts(sender) else { return false }
        let urls = Self.audioURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    /// A non-nil dragging source means the drag started inside BeatSnap — that's a beat on
    /// its way to a DAW, not an import.
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        canImport() && sender.draggingSource == nil && !Self.audioURLs(on: sender.draggingPasteboard).isEmpty
    }

    private func setTargeted(_ value: Bool) {
        guard isTargeted != value else { return }
        isTargeted = value
        onTargetChange?(value)
    }

    /// File URLs on the pasteboard whose contents are audio. This conformance filter is
    /// what makes a dropped PDF, folder or video simply do nothing.
    private static func audioURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.audio.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

extension URL {
    /// Whether this is an audio file, tested by declared content type rather than by
    /// matching a list of extensions. The pasteboard equivalent is
    /// `.urlReadingContentsConformToTypes`, which AppKit evaluates the same way.
    var isAudioFile: Bool {
        let type = try? resourceValues(forKeys: [.contentTypeKey]).contentType
        return type?.conforms(to: .audio) ?? false
    }
}

/// The panel's vibrancy view, doubling as the drag destination nearest the content.
final class DropTargetEffectView: NSVisualEffectView {
    private let dropHandler: AudioDropHandler

    init(dropHandler: AudioDropHandler) {
        self.dropHandler = dropHandler
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHandler.draggingEnded() }

    override func draggingEnded(_ sender: NSDraggingInfo) { dropHandler.draggingEnded() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler.performDrag(sender)
    }
}

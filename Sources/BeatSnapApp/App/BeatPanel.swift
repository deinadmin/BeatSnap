import AppKit
import SwiftUI

/// The floating window. An `NSPanel` rather than a plain window so it can sit above other
/// apps — including a full-screen DAW — without joining their Space.
/// `NSWindow` has `registerForDraggedTypes` but doesn't declare the destination protocol
/// itself, so the conformance is spelled out here.
final class BeatPanel: NSPanel, NSDraggingDestination {
    /// Panels default to refusing key status, which would make the URL field untypable.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Audio-file drops. Wired to the library by `AppDelegate`.
    let dropHandler = AudioDropHandler()
    let pasteHandler = AudioPasteHandler()

    convenience init(content: some View) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 770),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "BeatSnap"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // Deliberately NOT movable by background: that makes every pixel of the window a
        // drag handle, which swallows the mouse-down before a beat row can start its own
        // drag session. The header opts into window dragging explicitly instead.
        isMovableByWindowBackground = false

        // An empty unified toolbar is what insets the traffic lights: AppKit moves them
        // from x=9/centre 16pt to x=19/centre 26pt from the top and keeps them there
        // across every relayout. Far more robust than setting the button frames by hand.
        let toolbar = NSToolbar(identifier: "BeatSnapToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        toolbarStyle = .unified

        // Float above ordinary windows, stay reachable from every Space, and be allowed
        // over a full-screen app instead of forcing a Space switch.
        setKeepOnTop(AppSettings.shared.keepBeatSnapOnTop)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        minSize = NSSize(width: 380, height: 420)
        // Launch at the narrowest width the layout allows (`minSize.width`, mirrored by
        // RootView's `minWidth`) and tall, so the beat list shows as many rows as possible
        // while covering as little of the DAW as possible. AppKit shrinks this to fit if
        // the screen is shorter than 770pt.
        setContentSize(NSSize(width: 380, height: 770))

        // Vibrancy behind the SwiftUI content so the panel reads as a real macOS surface.
        //
        // Use the standard window material: it keeps the subtle adaptive translucency of a
        // normal macOS window without letting the desktop or DAW show strongly through it.
        let effect = DropTargetEffectView(dropHandler: dropHandler)
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Don't let the material darken/solidify when the panel loses focus — it stays
        // visible over a DAW, so it should look the same whether or not it's frontmost.
        effect.isEmphasized = false
        effect.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // With .fullSizeContentView the content spans the whole window, but SwiftUI would
        // still inset it below the titlebar. Drop the safe area so the header can sit
        // alongside the traffic lights.
        hosting.safeAreaRegions = []
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        contentView = effect
        isOpaque = false
        backgroundColor = .clear

        center()
        // Despite what the name suggests, this both saves *and* restores: if a frame was
        // stored under this name it is applied right here, silently overriding the size and
        // position set above. So changing the launch size means bumping the name too —
        // otherwise the old remembered frame wins forever. With no stored frame the call
        // leaves the window alone, so the size above applies once and user resizes persist
        // from then on.
        setFrameAutosaveName("BeatSnapPanel-380x770")

        // The window is the last stop in AppKit's dragging-destination search, so this is
        // the backstop for any path where the content view isn't asked.
        registerForDraggedTypes([.fileURL])
    }

    func setKeepOnTop(_ enabled: Bool) {
        isFloatingPanel = enabled
        level = enabled ? .floating : .normal
    }

    /// Handle Finder files before a focused SwiftUI text field can paste their names.
    /// Text and URL pastes continue through the normal responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow, AudioPasteHandler.isPasteShortcut(event), pasteHandler.paste(from: .general) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Dragging destination

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler.draggingEntered(sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler.draggingUpdated(sender)
    }

    func draggingExited(_ sender: NSDraggingInfo?) { dropHandler.draggingEnded() }

    func draggingEnded(_ sender: NSDraggingInfo) { dropHandler.draggingEnded() }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler.performDrag(sender)
    }
}

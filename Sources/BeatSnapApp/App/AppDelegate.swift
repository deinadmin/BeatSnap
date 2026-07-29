import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = BeatLibrary()
    private let preview = AudioPreview()
    private var statusItem: NSStatusItem?
    private var panel: BeatPanel?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        setupMainMenu()
        setupStatusItem()
        setupHotKey()
        makePanel()
        showPanel()

        Task { await Tools.updateYtDlpIfNeeded() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Main menu

    /// Build a main menu even though an accessory app never displays one.
    ///
    /// On macOS the standard editing shortcuts are the *key equivalents of the Edit menu* —
    /// a text field does not implement them itself. With no main menu, Cmd+A/C/V/X/Z simply
    /// do nothing. The items target `nil` so they travel the responder chain to whatever
    /// field editor is focused.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // The first item is the application menu; AppKit requires it to be present for the
        // menus after it to be consulted.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide BeatSnap", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Quit BeatSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menubar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "BeatSnap"
        )
        item.button?.toolTip = "BeatSnap"

        let menu = NSMenu()
        let show = NSMenuItem(
            title: "Show BeatSnap",
            action: #selector(showFromMenu),
            keyEquivalent: "b"
        )
        show.keyEquivalentModifierMask = [.command, .option, .control, .shift]
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        let folder = NSMenuItem(
            title: "Open Beats Folder",
            action: #selector(openFolderFromMenu),
            keyEquivalent: ""
        )
        folder.target = self
        menu.addItem(folder)

        let chooseFolder = NSMenuItem(
            title: "Change Download Folder…",
            action: #selector(chooseFolderFromMenu),
            keyEquivalent: ""
        )
        chooseFolder.target = self
        menu.addItem(chooseFolder)

        let resetFolder = NSMenuItem(
            title: "Use Default Folder",
            action: #selector(resetFolderFromMenu),
            keyEquivalent: ""
        )
        resetFolder.target = self
        menu.addItem(resetFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit BeatSnap",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func setupHotKey() {
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: GlobalHotKey.hyperModifiers
        ) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
    }

    // MARK: - Panel

    private func makePanel() {
        let root = RootView(library: library, preview: preview)
            .environment(library)
            .environment(preview)
        let panel = BeatPanel(content: root)
        panel.dropHandler.onTargetChange = { [weak self] targeted in
            self?.library.isDropTargeted = targeted
        }
        panel.dropHandler.onDrop = { [weak self] urls in
            guard let self else { return }
            Task { await self.library.importDroppedFiles(urls) }
        }
        self.panel = panel
    }

    @objc private func showFromMenu() { showPanel() }

    @objc private func openFolderFromMenu() { library.openBeatsFolder() }

    @objc private func chooseFolderFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        library.chooseDownloadFolder()
    }

    @objc private func resetFolderFromMenu() { library.resetDownloadFolder() }

    @objc private func quit() { NSApp.terminate(nil) }

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel else { return }
        checkClipboardForLink()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .beatSnapPanelShown, object: nil)
    }

    /// Offer up a YouTube link sitting on the clipboard, unless it's already downloaded.
    private func checkClipboardForLink() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let id = YouTubeDownloader.youtubeID(from: text)
        else { return }

        guard !library.beats.contains(where: { $0.youtubeId == id }) else { return }
        guard library.urlText.isEmpty, !library.isBusy else { return }
        library.urlText = text
    }
}

extension Notification.Name {
    /// Lets the UI focus the URL field whenever the panel is summoned.
    static let beatSnapPanelShown = Notification.Name("BeatSnapPanelShown")
}

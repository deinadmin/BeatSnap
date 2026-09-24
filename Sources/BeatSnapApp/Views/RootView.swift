import SwiftUI

struct RootView: View {
    @Bindable var library: BeatLibrary
    let preview: AudioPreview
    let tools: ToolStatus
    let onKeepOnTopChanged: (Bool) -> Void

    @FocusState private var urlFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingInfo = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                downloadBar
                Divider().opacity(0.6)
                content
            }

            if showingInfo {
                InfoCard(tools: tools, onKeepOnTopChanged: onKeepOnTopChanged) {
                    showingInfo = false
                }
            }

            // Above the info card: a drag is in progress, so its feedback wins.
            if library.isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: library.isDropTargeted)
        .animation(.easeOut(duration: 0.16), value: showingInfo)
        .frame(minWidth: 380, minHeight: 420)
        .overlay(alignment: .bottom) {
            ToastStack(center: library.toasts)
                .padding(8)
        }
        .onReceive(NotificationCenter.default.publisher(for: .beatSnapPanelShown)) { _ in
            // Let the panel settle before taking first responder.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                urlFieldFocused = true
            }
        }
        .alert(
            "Are you sure?",
            isPresented: Binding(
                get: { library.pendingLongVideo != nil },
                set: { if !$0 { library.pendingLongVideo = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { library.pendingLongVideo = nil }
            Button("Proceed") { library.confirmPendingLongVideo() }
        } message: {
            Text("This video is longer than 10 minutes, do you want to proceed?")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Text("BeatSnap").bold()) by Carlo")
                    .font(.system(size: 15))
                Text(library.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                CircleIconButton(systemName: "info", help: "BeatSnap by Carlo settings and info") {
                    showingInfo.toggle()
                }
                CircleIconButton(systemName: "folder", help: "Open beats folder") {
                    library.openBeatsFolder()
                }
                .contextMenu {
                    Button("Open Beats Folder") { library.openBeatsFolder() }
                    Button("Change Beats Folder…") { library.chooseDownloadFolder() }
                    Button("Reset Beats Folder to Default") { library.resetDownloadFolder() }
                        .disabled(!library.usingCustomFolder)
                }
            }
        }
        // The traffic lights end at x=79 and are centred 26pt below the window top.
        // Giving the header a 52pt band centres its content on exactly that line without
        // depending on the fonts' internal leading.
        .padding(.leading, 100)
        .padding(.trailing, Design.panelPadding)
        .frame(height: Design.titlebarBand)
        .contentShape(Rectangle())
        // The window is not movable by its background, so the header is the drag handle.
        .gesture(WindowDragGesture())
    }

    // MARK: - Download bar

    private var downloadBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Paste an audio or YouTube link…", text: $library.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary.opacity(0.6)))
                    // Never disabled: a link pasted mid-download just joins the queue.
                    .focused($urlFieldFocused)
                    .onSubmit { submit() }

                AccentButton(
                    title: library.isCheckingLink ? "Checking…" : "Download",
                    isBusy: library.isCheckingLink,
                    isEnabled: canSubmit,
                    action: submit
                )
            }
        }
        .padding(.horizontal, Design.panelPadding)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var canSubmit: Bool {
        !library.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !library.isCheckingLink
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await library.submitCurrentURL() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if library.isLoadingFolder && library.queue.isEmpty {
            FolderLoadingView()
        } else if library.beats.isEmpty && library.queue.isEmpty {
            EmptyLibraryView()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Queued work sits above the library, oldest first, so a batch drop reads
                    // top-to-bottom in the order it will be worked through.
                    ForEach(library.queue) { item in
                        QueueRow(item: item)
                    }
                    if library.isLoadingFolder {
                        FolderLoadingView()
                    }
                    ForEach(library.beats) { beat in
                        BeatRowView(beat: beat)
                    }
                }
                .padding(8)
                .animation(.easeOut(duration: 0.18), value: library.queue.count)
                // Animate the list's layout as a row gains or loses its transport bar.
                // A row-local animation fades the bar but cannot move its siblings.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: preview.pendingBeatID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: preview.activeBeatID)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct FolderLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            TwoToneSpinner(label: "Scanning beats folder")
                .accessibilityHidden(true)
            Text("Scanning beats folder…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// Shown while an audio file is held over the panel. Non-audio drags never get this far,
/// so its presence is itself the "yes, this will work" signal.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            // Blurs the interface rather than dimming it. A `Material` used *inside* the
            // hierarchy blends within the window (only `.containerBackground(for: .window)`
            // switches to behind-window), so the beat list genuinely goes soft instead of
            // the desktop bleeding through. The accent wash sits on top of the blur.
            Rectangle()
                .fill(.thinMaterial)
                .overlay(Design.bpmTint.opacity(0.08))

            card
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Design.bpmTint.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(7)
        )
    }

    /// Liquid Glass, matching the panel's glass header buttons and Download pill. The stroke
    /// keeps the card's edge readable where the glass and the blur behind it are similar.
    private var card: some View {
        VStack(spacing: 7) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(Design.bpmTint)
                .padding(.bottom, 1)
            Text("Drop to analyze")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Detects BPM and key, then adds it\nto your beats folder.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Design.bpmTint.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }
}

/// A queued, in-flight or failed item. Deliberately the same metrics as `BeatRowView` so a
/// row doesn't jump when it finishes and becomes a real beat.
private struct QueueRow: View {
    let item: QueueItem

    @Environment(BeatLibrary.self) private var library

    @State private var isHovering = false

    /// Only work that isn't running can be taken back: queued items and failed receipts.
    private var isDismissable: Bool { item.stage.isWaiting || item.stage.isFailed }

    var body: some View {
        HStack(spacing: 11) {
            StageTile(stage: item.stage)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.stage.label)
                    .font(.system(size: 11))
                    .foregroundStyle(item.stage.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if isDismissable && isHovering {
                RowIconButton(
                    systemName: "xmark",
                    help: item.stage.isFailed ? "Dismiss" : "Remove from queue"
                ) {
                    library.remove(item)
                }
                .transition(.opacity)
            }
        }
        .frame(minHeight: Design.rowContentHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // Waiting rows recede so the one being worked on reads as the active row.
        .opacity(item.stage.isWaiting ? 0.6 : 1)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCorner)
                .fill(.quaternary.opacity(isHovering ? 0.5 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

/// The preview tile's slot, showing what the item is currently doing.
private struct StageTile: View {
    let stage: QueueStage

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Design.tileCorner)
                .fill(.quaternary.opacity(0.55))

            if stage.isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            } else if stage.isWaiting {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else if let progress = stage.progress {
                // The progress follows the tile itself so it stays consistent with the
                // rounded-rectangle music-note tile shown once the beat is ready.
                RoundedRectangle(cornerRadius: Design.tileCorner - 1)
                    .stroke(.primary.opacity(0.12), lineWidth: 2)
                    .padding(1)
                RoundedRectangle(cornerRadius: Design.tileCorner - 1)
                    .trim(from: 0, to: min(1, max(0.02, progress)))
                    .stroke(Design.bpmTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
                    .animation(.easeOut(duration: 0.2), value: progress)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                IndeterminateTileBorder()
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Design.tileSize, height: Design.tileSize)
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No beats yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Paste a YouTube, direct audio, Google Drive, or\nDropbox link above — or drop an audio file here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

import SwiftUI

struct RootView: View {
    @Bindable var library: BeatLibrary
    let preview: AudioPreview

    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                downloadBar
                Divider().opacity(0.6)
                content
            }

            if library.isDropTargeted {
                DropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: library.isDropTargeted)
        .frame(minWidth: 380, minHeight: 420)
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
            Button("Proceed") {
                Task { await library.confirmPendingLongVideo() }
            }
        } message: {
            Text("This video is longer than 10 minutes, do you want to proceed?")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Beat Snap")
                    .font(.system(size: 15, weight: .bold))
                Text(library.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
                TextField("Paste a YouTube link…", text: $library.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary.opacity(0.6)))
                    .focused($urlFieldFocused)
                    .onSubmit { submit() }
                    .disabled(library.job != nil)

                AccentButton(
                    title: library.isCheckingLink ? "Checking…" : "Download",
                    isBusy: library.isCheckingLink,
                    isEnabled: canSubmit,
                    action: submit
                )
            }

            if let message = library.errorMessage {
                ErrorCallout(message: message) { library.errorMessage = nil }
            }
        }
        .padding(.horizontal, Design.panelPadding)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var canSubmit: Bool {
        !library.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !library.isBusy
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await library.submitCurrentURL() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if library.beats.isEmpty && library.job == nil {
            EmptyLibraryView()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    if let job = library.job {
                        JobRow(job: job)
                    }
                    ForEach(library.beats) { beat in
                        BeatRowView(beat: beat)
                    }
                }
                .padding(8)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// Shown while an audio file is held over the panel. Non-audio drags never get this far,
/// so its presence is itself the "yes, this will work" signal.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            // Mute the panel behind the prompt so it reads as a single target.
            Rectangle()
                .fill(.background.opacity(0.6))

            card
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Design.bpmTint.opacity(0.8),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(7)
        )
    }

    private var card: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Design.bpmTint)
            Text("Drop to analyze")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Detects BPM and key, then adds it\nto your beats folder.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Live row shown while a download is in flight.
private struct JobRow: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: Design.rowCorner)
                    .fill(.quaternary.opacity(0.55))
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }
            .frame(width: Design.tileSize, height: Design.tileSize)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(job.stage.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

private struct ErrorCallout: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
            Text("Paste a YouTube link above, or drop an audio file\nanywhere here, to detect its BPM and key.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

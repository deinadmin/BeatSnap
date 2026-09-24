import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One beat in the library: preview tile, title with BPM/key badges, and hover actions.
/// The whole row is the drag handle for exporting into a DAW or Finder.
struct BeatRowView: View {
    let beat: Beat

    @Environment(BeatLibrary.self) private var library
    @Environment(AudioPreview.self) private var preview

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var confirmingDelete = false
    @State private var editorScope: BeatLabelEditorScope?
    @State private var rowWidth: CGFloat = 360

    var body: some View {
        // Only the identity of the loaded beat is read here — the playhead itself is read
        // inside `BeatTransportBar`, so ticking the progress redraws the bar and not the row.
        let isActive = preview.isActive(beat)
        let download = library.downloads.transfers[beat.filePath]
        let state = BeatTransportState.resolve(
            isActive: isActive, isPending: preview.pendingBeatID == beat.id,
            isDownloading: download?.isDownloading == true
                || (preview.pendingBeatID == beat.id && beat.needsDownload && download == nil),
            hasError: download?.error != nil
        )

        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BeatPreviewControl(beat: beat, state: state)

                details

                Spacer(minLength: 0)

                if isHovering {
                    HStack(spacing: 2) {
                        RowIconButton(systemName: "slider.horizontal.3", help: "Edit BPM and key") {
                            openEditor(.all)
                        }
                        RowIconButton(systemName: "folder", help: "Show in Finder") {
                            library.revealInFinder(beat)
                        }
                        RowIconButton(systemName: "trash", help: "Delete", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            if state.showsProgress {
                BeatTransportBar(beat: beat, state: state)
                    .beatProgressPlacement()
                    .transition(.opacity)
            }

            CloudDownloadStatus(beat: beat)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: beat.needsDownload)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: beat.durationText)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCorner)
                .fill(.quaternary.opacity(isHovering || isActive ? 0.5 : 0))
        )
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .draggableBeat(beat, library: library, width: rowWidth, state: state)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Edit BPM & Key") { openEditor(.all) }
            Divider()
            Button("Show in Finder") { library.revealInFinder(beat) }
            Button("Delete", role: .destructive) { confirmingDelete = true }
        }
        .alert("Are you sure?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                preview.stopIfPlaying(beat)
                library.downloads.cancel(beat)
                library.delete(beat)
            }
        } message: {
            Text("This beat will be permanently removed from your library.")
        }
        .popover(item: $editorScope, arrowEdge: .trailing) { scope in
            BeatLabelEditor(beat: beat, scope: scope)
        }
    }

    private func openEditor(_ scope: BeatLabelEditorScope) {
        Task {
            do {
                _ = try await library.availableURL(for: beat)
                guard library.beats.contains(where: { $0.id == beat.id }) else { return }
                editorScope = scope
            } catch { /* The library surfaces download errors. */ }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(beat.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())

            HStack(spacing: 5) {
                EditableBadge(
                    text: "\(beat.bpm) BPM",
                    tint: Design.bpmTint,
                    help: "Edit BPM"
                ) {
                    openEditor(.bpm)
                }
                EditableBadge(text: beat.key, tint: Design.keyTint, help: "Edit key") {
                    openEditor(.key)
                }
                if beat.needsDownload {
                    Image(systemName: "icloud")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("Stored in the cloud")
                }
                if !beat.durationText.isEmpty {
                    Text(beat.durationText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The same compact chip as `Badge`, with a subtle hover edge to signal that this instance
/// is directly editable.
private struct EditableBadge: View {
    let text: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(tint.opacity(isHovering ? 0.22 : 0.14), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(tint.opacity(isHovering ? 0.38 : 0), lineWidth: 1)
                }
                .scaleEffect(isHovering ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovering = hovering }
        }
        .help(help)
    }
}

private extension View {
    /// Shared placement keeps the download track and playback track at the same baseline.
    func beatProgressPlacement() -> some View {
        padding(.horizontal, 8)
            .padding(.top, -4)
            .padding(.bottom, 6)
    }

    /// Native file drag-out. `NSItemProvider(contentsOf:)` advertises the real file, which
    /// is what lets Logic, FL Studio, Ableton and Finder accept the drop.
    func draggableBeat(_ beat: Beat, library: BeatLibrary, width: CGFloat,
                       state: BeatTransportState) -> some View {
        onDrag {
            BeatDragProvider.make(for: beat) { try await library.availableURL(for: beat) }
        } preview: {
            DragPreview(beat: beat, width: width, state: state)
        }
    }
}

/// A noninteractive copy of the visible row, shown under the cursor while dragging.
private struct DragPreview: View {
    let beat: Beat
    let width: CGFloat
    let state: BeatTransportState

    @Environment(AudioPreview.self) private var preview
    @Environment(BeatLibrary.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: Design.rowCorner)
                    .fill(.quaternary.opacity(0.55))
                    .overlay {
                        Image(systemName: preview.isPlaying(beat) ? "pause.fill" : "music.note")
                            .font(.system(size: preview.isPlaying(beat) ? 12 : 14, weight: .medium))
                            .foregroundStyle(preview.isActive(beat) ? Design.bpmTint : Color.secondary)
                    }
                    .frame(width: Design.tileSize, height: Design.tileSize)

                VStack(alignment: .leading, spacing: 4) {
                    Text(beat.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        Badge(text: "\(beat.bpm) BPM", tint: Design.bpmTint)
                        Badge(text: beat.key, tint: Design.keyTint)
                        if beat.needsDownload {
                            Image(systemName: "icloud")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        if !beat.durationText.isEmpty {
                            Text(beat.durationText)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    ForEach(["slider.horizontal.3", "folder", "trash"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            if state.showsProgress {
                GeometryReader { geometry in
                    BeatProgressTrack(
                        width: geometry.size.width,
                        fraction: state == .playback ? preview.progress
                            : (library.downloads.transfers[beat.filePath]?.fraction
                               ?? (state == .preparing ? 1 : nil)),
                        isPlayback: state == .playback
                    )
                    .frame(height: BeatProgressMetrics.trackHeight)
                    .frame(height: BeatProgressMetrics.bandHeight, alignment: .bottom)
                }
                .frame(height: BeatProgressMetrics.bandHeight)
                .beatProgressPlacement()
            }

            if let download = library.downloads.transfers[beat.filePath],
               !download.isDownloading, let error = download.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(.red)
                    Spacer(minLength: 4)
                    Text("Retry")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
        }
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.rowCorner))
    }
}

/// Music-note tile that flips to a transport control: play on hover or while paused
/// mid-track, pause while playing.
private struct BeatPreviewControl: View {
    let beat: Beat
    let state: BeatTransportState
    @Environment(BeatLibrary.self) private var library
    @Environment(AudioPreview.self) private var preview

    var body: some View {
        PreviewTile(isActive: preview.isActive(beat), isPlaying: preview.isPlaying(beat),
                    needsDownload: beat.needsDownload, isBusy: state.isBusy,
                    isDownloading: state == .downloading) {
            preview.toggle(beat, library: library)
        }
    }
}

private struct CloudDownloadStatus: View {
    let beat: Beat
    @Environment(BeatLibrary.self) private var library
    @Environment(AudioPreview.self) private var preview

    var body: some View {
        if let download = library.downloads.transfers[beat.filePath] {
            if !download.isDownloading, let error = download.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(.red)
                    Spacer(minLength: 4)
                    Button("Retry") { preview.toggle(beat, library: library) }
                        .buttonStyle(.plain)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
        }
    }
}

private struct PreviewTile: View {
    let isActive: Bool
    let isPlaying: Bool
    let needsDownload: Bool
    let isBusy: Bool
    let isDownloading: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var symbol: String {
        if isPlaying { return "pause.fill" }
        if needsDownload && isHovering { return "icloud.and.arrow.down" }
        return isActive || isHovering ? "play.fill" : "music.note"
    }

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Design.rowCorner)
                .fill(.quaternary.opacity(0.55))
                .overlay {
                    ZStack {
                        if isBusy {
                            IndeterminateTileBorder()
                            Image(systemName: isDownloading ? "arrow.down" : "waveform")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        } else {
                            Image(systemName: symbol)
                                .font(.system(size: symbol == "music.note" ? 14 : 12, weight: .medium))
                                .foregroundStyle(isActive ? Design.bpmTint : Color.secondary)
                                .contentTransition(.symbolEffect(.replace.offUp))
                                // Hover feedback has to read as instant, so the symbol swap runs far
                                // shorter than the replace effect's default timing.
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: symbol)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isBusy)
                }
                .frame(width: Design.tileSize, height: Design.tileSize)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isBusy)
        .help(isPlaying ? "Pause" : (needsDownload ? "Download and play" : "Play"))
        .accessibilityLabel(isPlaying ? "Pause" : (needsDownload ? "Download and play" : "Play"))
    }
}

private enum BeatProgressMetrics {
    static let bandHeight: CGFloat = 9
    static let trackHeight: CGFloat = 3
    static let hoverTrackHeight: CGFloat = 5
}

/// Both download and playback use the very same capsule track, tint, and minimum fill.
private struct BeatProgressTrack: View {
    let width: CGFloat
    let fraction: Double?
    var isPlayback = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary.opacity(0.8))
            ZStack(alignment: .leading) {
                if let fraction {
                    Capsule()
                        .fill(Design.bpmTint)
                        .frame(width: max(BeatProgressMetrics.trackHeight, width * min(1, max(0, fraction))))
                } else {
                    IndeterminateBeatProgress(width: width)
                }
            }
            .frame(width: width, alignment: .leading)
            .id(isPlayback)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPlayback)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: fraction == nil)
    }
}

private struct IndeterminateBeatProgress: View {
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        Capsule()
            .fill(Design.bpmTint)
            .frame(width: width * 0.25)
            .offset(x: reduceMotion ? width * 0.375 : (moving ? width * 0.75 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: moving)
            .onAppear { moving = true }
    }
}

/// Seek bar along the bottom edge of the loaded beat's row. Click or drag anywhere on it to
/// move the playhead; hovering shows a time readout that tracks the cursor.
private struct BeatTransportBar: View {
    let beat: Beat
    let state: BeatTransportState

    @Environment(AudioPreview.self) private var preview
    @Environment(BeatLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cursor position in the bar's own coordinate space, nil when the mouse is elsewhere.
    @State private var cursorX: CGFloat?
    @State private var tooltipWidth: CGFloat = 0

    /// The track is hairline-thin, but the band that accepts clicks is not.
    private let bandHeight = BeatProgressMetrics.bandHeight
    private let trackHeight = BeatProgressMetrics.trackHeight
    private let hoverTrackHeight = BeatProgressMetrics.hoverTrackHeight

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            track(barWidth: width)
                .frame(height: cursorX == nil ? trackHeight : hoverTrackHeight)
                .frame(width: width, height: bandHeight, alignment: .bottom)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.1), value: cursorX == nil)
                .overlay(alignment: .topLeading) { tooltip(barWidth: width) }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    // Rounded to a whole point so a mouse crawling across the bar does not
                    // invalidate the view on every sub-pixel step.
                    case .active(let point): setCursorX(point.x.rounded())
                    case .ended: cursorX = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            setCursorX(value.location.x.rounded())
                            guard state == .playback else { return }
                            preview.seek(toFraction: fraction(at: value.location.x, barWidth: width))
                        }
                )
        }
        .frame(height: bandHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state == .playback ? "Playback position" : "Download progress")
        .accessibilityValue(accessibilityProgress)
    }

    private var accessibilityProgress: String {
        if state == .playback { return "\(timeText(preview.currentTime)) of \(timeText(preview.duration))" }
        if state == .preparing { return "Preparing playback" }
        return library.downloads.transfers[beat.filePath]?.fraction.map { "\(Int($0 * 100)) percent" }
            ?? "In progress"
    }

    private func track(barWidth: CGFloat) -> some View {
        let fraction = state == .playback ? preview.progress
            : (library.downloads.transfers[beat.filePath]?.fraction ?? (state == .preparing ? 1 : nil))
        return BeatProgressTrack(width: barWidth, fraction: fraction, isPlayback: state == .playback)
            .animation(reduceMotion ? nil : .linear(duration: state == .playback ? 0.05 : 0.25), value: fraction)
    }

    @ViewBuilder
    private func tooltip(barWidth: CGFloat) -> some View {
        if state == .playback, let cursorX, barWidth > 0 {
            let hovered = fraction(at: cursorX, barWidth: barWidth) * preview.duration
            Text("\(timeText(hovered)) / \(timeText(preview.duration))")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 1)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tooltipWidth = $0 }
                // Centred on the cursor, but kept inside the row rather than hanging off it.
                .offset(x: min(max(0, cursorX - tooltipWidth / 2), max(0, barWidth - tooltipWidth)), y: -25)
                // Hidden for the frame before its width is known, which would otherwise
                // place it uncentred and then visibly snap into position.
                .opacity(tooltipWidth > 0 ? 1 : 0)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func setCursorX(_ x: CGFloat) {
        if cursorX != x { cursorX = x }
    }

    private func fraction(at x: CGFloat, barWidth: CGFloat) -> Double {
        guard barWidth > 0 else { return 0 }
        return min(1, max(0, x / barWidth))
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

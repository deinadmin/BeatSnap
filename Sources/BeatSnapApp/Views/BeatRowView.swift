import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One beat in the library: preview tile, title with BPM/key badges, and hover actions.
/// The title area is the drag handle for exporting into a DAW or Finder.
struct BeatRowView: View {
    let beat: Beat

    @Environment(BeatLibrary.self) private var library
    @Environment(AudioPreview.self) private var preview

    @State private var isHovering = false
    @State private var confirmingDelete = false

    var body: some View {
        // Only the identity of the loaded beat is read here — the playhead itself is read
        // inside `PlaybackBar`, so ticking the progress redraws the bar and not the row.
        let isActive = preview.isActive(beat)

        VStack(spacing: 0) {
            HStack(spacing: 11) {
                PreviewTile(isActive: isActive, isPlaying: preview.isPlaying(beat)) {
                    preview.toggle(beat)
                }

                details
                    .draggableBeat(beat)

                Spacer(minLength: 0)

                if isHovering {
                    HStack(spacing: 2) {
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

            if isActive {
                PlaybackBar { preview.seek(toFraction: $0) }
                    .padding(.horizontal, 8)
                    // The bar's click band is taller than the track it draws, so it reclaims
                    // part of the row's own bottom padding instead of stacking on top of it —
                    // the track then sits close under the beat without shrinking its target.
                    .padding(.top, -4)
                    .padding(.bottom, 6)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isActive)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCorner)
                .fill(.quaternary.opacity(isHovering || isActive ? 0.5 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Show in Finder") { library.revealInFinder(beat) }
            Button("Delete", role: .destructive) { confirmingDelete = true }
        }
        .alert("Are you sure?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                preview.stopIfPlaying(beat)
                library.delete(beat)
            }
        } message: {
            Text("This beat will be permanently removed from your library.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(beat.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            HStack(spacing: 5) {
                Badge(text: "\(beat.bpm) BPM", tint: Design.bpmTint)
                Badge(text: beat.key, tint: Design.keyTint)
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

private extension View {
    /// Native file drag-out. `NSItemProvider(contentsOf:)` advertises the real file, which
    /// is what lets Logic, FL Studio, Ableton and Finder accept the drop.
    func draggableBeat(_ beat: Beat) -> some View {
        onDrag {
            let provider = NSItemProvider(contentsOf: beat.fileURL) ?? NSItemProvider()
            provider.suggestedName = beat.fileName
            return provider
        } preview: {
            DragPreview(beat: beat)
        }
    }
}

/// Compact card shown under the cursor while dragging, mirroring the row itself.
private struct DragPreview: View {
    let beat: Beat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(beat.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Badge(text: "\(beat.bpm) BPM", tint: Design.bpmTint)
                Badge(text: beat.key, tint: Design.keyTint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Music-note tile that flips to a transport control: play on hover or while paused
/// mid-track, pause while playing.
private struct PreviewTile: View {
    let isActive: Bool
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var symbol: String {
        if isPlaying { return "pause.fill" }
        return isActive || isHovering ? "play.fill" : "music.note"
    }

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Design.rowCorner)
                .fill(.quaternary.opacity(0.55))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "music.note" ? 14 : 12, weight: .medium))
                        .foregroundStyle(isActive ? Design.bpmTint : Color.secondary)
                        .contentTransition(.symbolEffect(.replace.offUp))
                        // Hover feedback has to read as instant, so the symbol swap runs far
                        // shorter than the replace effect's default timing.
                        .animation(.easeOut(duration: 0.07), value: symbol)
                }
                .frame(width: Design.tileSize, height: Design.tileSize)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isPlaying ? "Pause" : "Play")
    }
}

/// Seek bar along the bottom edge of the loaded beat's row. Click or drag anywhere on it to
/// move the playhead; hovering shows a time readout that tracks the cursor.
private struct PlaybackBar: View {
    let seek: (Double) -> Void

    @Environment(AudioPreview.self) private var preview

    /// Cursor position in the bar's own coordinate space, nil when the mouse is elsewhere.
    @State private var cursorX: CGFloat?
    @State private var tooltipWidth: CGFloat = 0

    /// The track is hairline-thin, but the band that accepts clicks is not.
    private let bandHeight: CGFloat = 9
    private let trackHeight: CGFloat = 3
    private let hoverTrackHeight: CGFloat = 5

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
                            seek(fraction(at: value.location.x, barWidth: width))
                        }
                )
        }
        .frame(height: bandHeight)
    }

    private func track(barWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.quaternary.opacity(0.8))
            Capsule()
                .fill(Design.bpmTint)
                .frame(width: max(trackHeight, barWidth * preview.progress))
                .animation(.linear(duration: 0.05), value: preview.progress)
        }
    }

    @ViewBuilder
    private func tooltip(barWidth: CGFloat) -> some View {
        if let cursorX, barWidth > 0 {
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

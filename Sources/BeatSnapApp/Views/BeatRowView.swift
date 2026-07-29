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

    private var isPlaying: Bool { preview.isPlaying(beat) }

    var body: some View {
        HStack(spacing: 11) {
            PreviewTile(
                isPlaying: isPlaying,
                progress: isPlaying ? preview.progress : 0
            ) {
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
        .background(
            RoundedRectangle(cornerRadius: Design.rowCorner)
                .fill(.quaternary.opacity(isHovering ? 0.5 : 0))
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

/// Music-note tile that becomes a play button on hover and a progress ring while playing.
private struct PreviewTile: View {
    let isPlaying: Bool
    let progress: Double
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Design.rowCorner)
                    .fill(.quaternary.opacity(0.55))

                if isPlaying {
                    Circle()
                        .stroke(.primary.opacity(0.12), lineWidth: 2)
                        .padding(3)
                    Circle()
                        .trim(from: 0, to: max(0.001, progress))
                        .stroke(Design.bpmTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                        .animation(.linear(duration: 0.05), value: progress)
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: isHovering ? "play.fill" : "music.note")
                        .font(.system(size: isHovering ? 12 : 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: Design.tileSize, height: Design.tileSize)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isPlaying ? "Pause" : "Preview")
    }
}

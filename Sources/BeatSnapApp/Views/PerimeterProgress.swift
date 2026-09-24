import SwiftUI

/// The tile stays fixed; only the highlighted portion travels along its perimeter.
/// TimelineView keeps successive laps continuous without resetting an animation state.
struct IndeterminateTileBorder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let lap = context.date.timeIntervalSinceReferenceDate / 1.15
            ZStack {
                RoundedRectangle(cornerRadius: Design.rowCorner - 1)
                    .stroke(Design.bpmTint.opacity(0.22), lineWidth: 2)
                RoundedRectangleProgressSegment(phase: reduceMotion ? 0 : lap,
                                                cornerRadius: Design.rowCorner - 1)
                    .stroke(Design.bpmTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .padding(1)
        }
        .accessibilityHidden(true)
    }
}

struct RoundedRectangleProgressSegment: Shape {
    var phase: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let outline = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
        let start = phase - phase.rounded(.down)
        let end = start + 0.28
        var segment = outline.trimmedPath(from: start, to: min(end, 1))
        // Keep the entire segment visible while it crosses the path's closing point.
        if end > 1 {
            segment.addPath(outline.trimmedPath(from: 0, to: end - 1))
        }
        return segment
    }
}

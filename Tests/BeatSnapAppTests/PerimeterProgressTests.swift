import SwiftUI
import Testing
@testable import BeatSnapApp

struct PerimeterProgressTests {
    @Test func strokeStaysInsideTileThroughoutEachLap() {
        let tile = CGRect(x: 0, y: 0, width: 36, height: 36)
        for step in 0...200 {
            let path = RoundedRectangleProgressSegment(phase: CGFloat(step) / 100, cornerRadius: 8)
                .path(in: tile.insetBy(dx: 1, dy: 1))
                .strokedPath(StrokeStyle(lineWidth: 2, lineCap: .round))
            #expect(tile.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingRect))
        }
    }

    @Test func wrappingPreservesTheSegmentAndRepeatsExactly() {
        let rect = CGRect(x: 0, y: 0, width: 34, height: 34)
        func path(_ phase: CGFloat) -> Path {
            RoundedRectangleProgressSegment(phase: phase, cornerRadius: 8).path(in: rect)
        }
        #expect(path(0) == path(1))
        #expect(path(0.25) == path(10.25))
        let outline = RoundedRectangle(cornerRadius: 8).path(in: rect)
        var wrapped = outline.trimmedPath(from: 0.875, to: 1)
        wrapped.addPath(outline.trimmedPath(from: 0, to: 0.875 + 0.28 - 1))
        #expect(path(0.875) == wrapped)
    }
}

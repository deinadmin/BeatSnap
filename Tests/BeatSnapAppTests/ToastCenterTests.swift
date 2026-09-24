import Foundation
import Testing
@testable import BeatSnapApp

@MainActor
struct ToastCenterTests {
    @Test func fourthToastImmediatelyEvictsOldest() async throws {
        let center = ToastCenter()
        center.show(.error, title: "First", message: "One")
        let oldest = center.items[0].id
        center.show(.success, title: "Second", message: "Two")
        center.show(.info, title: "Third", message: "Three")
        center.show(.error, title: "Fourth", message: "Four")
        #expect(center.items.map(\.title) == ["Second", "Third", "Fourth"])
        // A stale timeout belonging to the evicted card cannot remove a newer card.
        center.dismiss(oldest)
        #expect(center.items.count == 3)
        center.dismiss(center.items[1].id)
        #expect(center.items[1].isDismissing)
        try await Task.sleep(for: .milliseconds(300))
        #expect(center.items.map(\.title) == ["Second", "Fourth"])
    }

    @Test func repeatedActionsHaveSeparateIdentities() {
        let center = ToastCenter()
        for _ in 0..<4 { center.show(.success, title: "Tags updated", message: "Beat") }
        #expect(center.items.count == 3)
        #expect(Set(center.items.map(\.id)).count == 3)
    }

    @Test func forwardedErrorsAreOnlyReportedOnce() {
        let center = ToastCenter()
        let original = CocoaError(.fileReadNoSuchFile)
        let reported = center.report(original, title: "Download failed")
        center.report(reported, title: "Playback failed")
        center.report(CancellationError(), title: "Cancelled")
        #expect(center.items.count == 1)
        #expect(center.items.first?.kind == .error)
        #expect(reported.localizedDescription == original.localizedDescription)
    }
}

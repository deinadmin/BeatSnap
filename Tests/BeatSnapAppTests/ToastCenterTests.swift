import Foundation
import Testing
@testable import BeatSnapApp

@MainActor
struct ToastCenterTests {
    @Test func clearRemovesActiveAndDismissingToastsBeforeReplacement() async throws {
        let center = ToastCenter()
        center.show(.error, title: "Activation failed", message: "Try again")
        let outgoingID = center.items[0].id
        center.dismiss(outgoingID)
        center.show(.info, title: "Older toast", message: "Message")

        center.clear()
        #expect(center.items.isEmpty)
        center.show(.info, title: "BeatSnap activated", message: "BeatSnap has been activated successfully.")
        center.dismiss(outgoingID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(center.items.map(\.title) == ["BeatSnap activated"])
        #expect(center.items.first?.kind == .info)
        #expect(center.items.first?.isDismissing == false)
    }

    @Test func fourthToastFadesOutOldest() async throws {
        let center = ToastCenter()
        center.show(.error, title: "First", message: "One")
        let oldest = center.items[0].id
        center.show(.success, title: "Second", message: "Two")
        center.show(.info, title: "Third", message: "Three")
        center.show(.error, title: "Fourth", message: "Four")
        #expect(center.items.map(\.title) == ["First", "Second", "Third", "Fourth"])
        #expect(center.items[0].id == oldest)
        #expect(center.items[0].isDismissing)
        #expect(center.items[0].isEvicted)
        #expect(center.items.dropFirst().allSatisfy { !$0.isDismissing && !$0.isEvicted })
        // A stale dismissal of the evicted card cannot remove a newer card.
        center.dismiss(oldest)
        #expect(center.items.count == 4)
        center.dismiss(center.items[2].id)
        #expect(center.items[2].isDismissing)
        #expect(!center.items[2].isEvicted)
        try await Task.sleep(for: .milliseconds(300))
        #expect(center.items.map(\.title) == ["Second", "Fourth"])
    }

    @Test func repeatedActionsHaveSeparateIdentities() async throws {
        let center = ToastCenter()
        for _ in 0..<4 { center.show(.success, title: "Tags updated", message: "Beat") }
        #expect(center.items.count == 4)
        #expect(center.items[0].isDismissing)
        #expect(Set(center.items.map(\.id)).count == 4)
        try await Task.sleep(for: .milliseconds(300))
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

import Foundation
import Testing
@testable import BeatSnapApp

@MainActor
struct UpdateCheckerTests {
    private func checker(current: String = "1.0.0") -> UpdateChecker {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests-\(UUID().uuidString)")!
        return UpdateChecker(defaults: defaults, currentVersion: current)
    }

    @Test func versionOrdering() {
        #expect(AppVersion("1.0.1")! > AppVersion("1.0.0")!)
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")! || !(AppVersion("1.0")! < AppVersion("1.0.0")!))
        #expect(AppVersion("2.0.0-beta.1")! < AppVersion("2.0.0")!)
        #expect(AppVersion("abc") == nil)
    }

    @Test func offersOnlyNewerVersions() {
        let sut = checker()
        let now = Date()
        #expect(sut.shouldOffer(.init(version: "1.0.1", notes: nil, minimumMacOS: nil), now: now))
        #expect(!sut.shouldOffer(.init(version: "1.0.0", notes: nil, minimumMacOS: nil), now: now))
        #expect(!sut.shouldOffer(.init(version: "0.9.0", notes: nil, minimumMacOS: nil), now: now))
        #expect(!sut.shouldOffer(.init(version: "1.0.1", notes: nil, minimumMacOS: "999.0"), now: now))
    }

    @Test func remindLaterSilencesTheSameVersionForExactly24Hours() {
        let sut = checker()
        let now = Date()
        sut.reminder = UpdateReminder(version: "1.0.1", dueDate: now.addingTimeInterval(UpdateConfig.remindInterval))
        let same = UpdateManifest(version: "1.0.1", notes: nil, minimumMacOS: nil)
        #expect(!sut.shouldOffer(same, now: now.addingTimeInterval(UpdateConfig.remindInterval - 1)))
        #expect(sut.shouldOffer(same, now: now.addingTimeInterval(UpdateConfig.remindInterval)))
        // A newer release is never held back by an older reminder.
        #expect(sut.shouldOffer(.init(version: "1.0.2", notes: nil, minimumMacOS: nil), now: now))
    }

    @Test func wakesWhenAReminderComesDue() {
        let sut = checker()
        let now = Date()
        #expect(sut.secondsUntilNextCheck(now: now) == UpdateConfig.pollInterval)
        sut.reminder = UpdateReminder(version: "1.0.1", dueDate: now.addingTimeInterval(600))
        #expect(sut.secondsUntilNextCheck(now: now) < 601)
    }

    @Test func messageShowsNotesAsBullets() {
        let manifest = UpdateManifest(version: "1.0.1", notes: "Faster.\n- One\n* Two", minimumMacOS: nil)
        let text = UpdateChecker.message(for: manifest, currentVersion: "1.0.0")
        #expect(text.contains("• One\n• Two"))
        #expect(text.hasPrefix("BeatSnap 1.0.1 is available"))
    }
}

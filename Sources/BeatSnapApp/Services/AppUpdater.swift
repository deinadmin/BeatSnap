import Foundation
import Sparkle

/// Where BeatSnap finds updates. Override for testing:
/// `defaults write com.carl.beatsnap updateSiteURL http://localhost:8088/`
/// (or launch with `-updateSiteURL http://localhost:8088/`).
enum UpdateConfig {
    static let defaultSiteURL = "https://beatsnap.designedbycarl.de/"
    static let siteURLKey = "updateSiteURL"

    static var siteURL: URL {
        let configured = UserDefaults.standard.string(forKey: siteURLKey)
        return URL(string: configured ?? "") ?? URL(string: defaultSiteURL)!
    }

    /// Sparkle's feed, generated from the published releases.
    static var appcastURL: URL { siteURL.appendingPathComponent("appcast.php") }
}

/// Automatic updates with Sparkle's standard dialogs: it checks on a schedule, shows the
/// release notes, downloads and verifies the DMG, replaces the app and relaunches.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    enum Probe: Equatable {
        case updateAvailable
        case upToDate
        case failed(String)
    }

    private var controller: SPUStandardUpdaterController!
    private var probeContinuation: CheckedContinuation<Probe, Never>?
    private var probeFoundUpdate = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() { controller.startUpdater() }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Looks for an update without showing any Sparkle UI, so the settings card can report
    /// the result itself. When one exists the caller follows up with `checkForUpdates()`.
    func probe() async -> Probe {
        guard probeContinuation == nil else { return .failed("An update check is already running.") }
        guard controller.updater.canCheckForUpdates else {
            return .failed("Couldn't check for BeatSnap updates.")
        }
        probeFoundUpdate = false
        return await withCheckedContinuation { continuation in
            probeContinuation = continuation
            controller.updater.checkForUpdateInformation()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { probeFoundUpdate = true }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            guard updateCheck == .updateInformation, let continuation = probeContinuation else { return }
            probeContinuation = nil
            if probeFoundUpdate {
                continuation.resume(returning: .updateAvailable)
            } else if let error, (error as NSError).code != Int(SUError.noUpdateError.rawValue) {
                continuation.resume(returning: .failed("Couldn't check for BeatSnap updates."))
            } else {
                continuation.resume(returning: .upToDate)
            }
        }
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { UpdateConfig.appcastURL.absoluteString }
    }
}

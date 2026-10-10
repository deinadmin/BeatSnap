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
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() { controller.startUpdater() }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { UpdateConfig.appcastURL.absoluteString }
    }
}

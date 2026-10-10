import AppKit
import Foundation

/// Where BeatSnap looks for new releases. The site also serves `api/latest.php`.
enum UpdateConfig {
    static let defaultSiteURL = "https://beatsnap.designedbycarl.de/"
    /// Override for testing: `defaults write com.carl.beatsnap updateSiteURL http://localhost:8088/`
    /// (or launch with `-updateSiteURL http://localhost:8088/`).
    static let siteURLKey = "updateSiteURL"

    /// First check after launch is delayed so the alert never greets the user instantly.
    static let launchDelay: Duration = .seconds(10)
    /// "Remind me later" hides the same version for exactly this long.
    static let remindInterval: TimeInterval = 24 * 60 * 60
    /// While running, the API is polled at this interval (or when a reminder comes due).
    static let pollInterval: TimeInterval = 6 * 60 * 60

    static var siteURL: URL {
        let configured = UserDefaults.standard.string(forKey: siteURLKey)
        return URL(string: configured ?? "") ?? URL(string: defaultSiteURL)!
    }

    static var apiURL: URL { siteURL.appendingPathComponent("api/latest.php") }
}

/// Subset of `api/latest.php` the app needs.
struct UpdateManifest: Decodable, Equatable {
    let version: String
    let notes: String?
    let minimumMacOS: String?

    enum CodingKeys: String, CodingKey {
        case version, notes
        case minimumMacOS = "minimum_macos"
    }
}

/// Version strings like "1.0.1" or "1.1.0-beta.2". A pre-release sorts below its release.
struct AppVersion: Comparable, Equatable {
    let numbers: [Int]
    let isPrerelease: Bool

    init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.contains(nil) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        isPrerelease = parts.count > 1
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return lhs.isPrerelease && !rhs.isPrerelease
    }
}

/// Persisted "Remind me later" state: which version was postponed and until when.
struct UpdateReminder: Equatable {
    var version: String
    var dueDate: Date

    /// Only the postponed version is silenced; a newer release prompts straight away.
    func suppresses(version candidate: String, now: Date) -> Bool {
        candidate == version && now < dueDate
    }
}

/// Checks the website for a newer release and offers it in a native alert.
@MainActor
final class UpdateChecker {
    private enum Keys {
        static let remindVersion = "updateRemindVersion"
        static let remindDate = "updateRemindDate"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: String
    private var loop: Task<Void, Never>?
    private var isPresenting = false
    /// A version the user already answered "Update" for in this session.
    private var openedVersion: String?

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        currentVersion: String? = nil
    ) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var reminder: UpdateReminder? {
        get {
            guard let version = defaults.string(forKey: Keys.remindVersion),
                  let date = defaults.object(forKey: Keys.remindDate) as? Date
            else { return nil }
            return UpdateReminder(version: version, dueDate: date)
        }
        set {
            defaults.set(newValue?.version, forKey: Keys.remindVersion)
            defaults.set(newValue?.dueDate, forKey: Keys.remindDate)
        }
    }

    /// Starts checking 10 seconds after launch, then keeps checking while the app runs.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: UpdateConfig.launchDelay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkNow()
                try? await Task.sleep(for: .seconds(self.secondsUntilNextCheck()))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Wakes exactly when a pending reminder comes due, otherwise at the regular poll interval.
    func secondsUntilNextCheck(now: Date = Date()) -> TimeInterval {
        guard let reminder, reminder.dueDate > now else { return UpdateConfig.pollInterval }
        return min(UpdateConfig.pollInterval, reminder.dueDate.timeIntervalSince(now) + 0.5)
    }

    func checkNow(now: Date = Date()) async {
        guard !isPresenting, let manifest = await fetchManifest(), shouldOffer(manifest, now: now) else {
            return
        }
        present(manifest)
    }

    func shouldOffer(_ manifest: UpdateManifest, now: Date) -> Bool {
        guard let remote = AppVersion(manifest.version),
              let local = AppVersion(currentVersion),
              remote > local,
              manifest.version != openedVersion,
              runsOnThisMac(manifest.minimumMacOS)
        else { return false }
        return !(reminder?.suppresses(version: manifest.version, now: now) ?? false)
    }

    private func runsOnThisMac(_ minimum: String?) -> Bool {
        guard let minimum, let required = AppVersion(minimum) else { return true }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let running = AppVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        return running.map { $0 >= required } ?? true
    }

    private func fetchManifest() async -> UpdateManifest? {
        var request = URLRequest(url: UpdateConfig.apiURL, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("BeatSnap/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    // MARK: - Alert

    private func present(_ manifest: UpdateManifest) {
        isPresenting = true
        defer { isPresenting = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "New Update available"
        alert.informativeText = Self.message(for: manifest, currentVersion: currentVersion)
        alert.addButton(withTitle: "Update BeatSnap")
        alert.addButton(withTitle: "Remind me later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openedVersion = manifest.version
            reminder = nil
            NSWorkspace.shared.open(UpdateConfig.siteURL)
        } else {
            reminder = UpdateReminder(
                version: manifest.version,
                dueDate: Date().addingTimeInterval(UpdateConfig.remindInterval)
            )
        }
    }

    /// "What's new" from the API, with "- item" lines shown as bullets.
    static func message(for manifest: UpdateManifest, currentVersion: String) -> String {
        let notes = (manifest.notes ?? "")
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
                    return "• " + trimmed.dropFirst(marker.count)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let header = "BeatSnap \(manifest.version) is available. You have \(currentVersion)."
        return notes.isEmpty ? header : header + "\n\n" + notes
    }
}

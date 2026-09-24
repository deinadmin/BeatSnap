import Foundation
import Observation

/// The versions of the bundled command-line tools, and the state of the yt-dlp self-update,
/// in a form the info card can show.
///
/// yt-dlp is the only tool that updates on its own: it's a 3 MB zipapp that YouTube keeps
/// invalidating. ffmpeg and Python are large static payloads inside the .app, so their
/// versions are read-only here and only change when the app is rebuilt.
@MainActor
@Observable
final class ToolStatus {
    enum Phase: Equatable {
        case idle
        case checking
        /// nil while the total download size is still unknown.
        case downloading(Double?)
        case upToDate
        case updated(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading: true
            default: false
            }
        }
    }

    private(set) var ytDlpVersion: String?
    private(set) var ffmpegVersion: String?
    /// False until the first read finishes, so a nil version can be told apart from a tool
    /// that failed to run.
    private(set) var hasReadVersions = false
    private(set) var phase: Phase = .idle {
        didSet {
            if case .failed(let message) = phase {
                toasts.show(.error, title: "Could not update yt-dlp", message: message)
            }
        }
    }
    /// Mirrors the persisted timestamp; kept here because `AppSettings` isn't observable.
    private(set) var lastChecked: Date?

    private let toasts: ToastCenter

    init(toasts: ToastCenter) {
        self.toasts = toasts
        lastChecked = AppSettings.shared.lastToolUpdateCheck
    }

    /// Read the versions of the tools on disk. Two `--version` invocations, so the result is
    /// kept until an update replaces one of them.
    func loadVersions(force: Bool = false) async {
        guard force || !hasReadVersions else { return }
        async let ytdlp = Tools.ytDlpVersion()
        async let ffmpeg = Tools.ffmpegVersion()
        ytDlpVersion = await ytdlp
        ffmpegVersion = await ffmpeg
        hasReadVersions = true
    }

    /// The launch-time path: look at most once a day, so the app doesn't hit GitHub on every
    /// hotkey press. The outcome is left in `phase` for whenever the info card is opened.
    func updateIfDue() async {
        Log.info("trace: updateIfDue enter")
        await loadVersions()
        Log.info("trace: versions ytdlp=\(ytDlpVersion ?? "nil") ffmpeg=\(ffmpegVersion ?? "nil") lastChecked=\(lastChecked?.description ?? "nil")")
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Tools.updateCheckInterval {
            return
        }
        await update()
    }

    /// The info card's button: always checks, whatever the daily throttle says.
    func checkForUpdates() async {
        await update()
    }

    private func update() async {
        guard !phase.isBusy else { return }
        phase = .checking
        lastChecked = Date()
        AppSettings.shared.lastToolUpdateCheck = lastChecked

        await loadVersions()
        Log.info("trace: asking GitHub")
        guard let latest = await Tools.latestYtDlpRelease() else {
            phase = .failed("Couldn't reach GitHub to check for updates.")
            return
        }
        Log.info("trace: latest=\(latest) current=\(ytDlpVersion ?? "nil")")
        guard latest != ytDlpVersion else {
            phase = .upToDate
            return
        }

        phase = .downloading(0)
        do {
            try await Tools.installYtDlp(tag: latest) { [weak self] fraction in
                Task { @MainActor in self?.report(fraction) }
            }
            await loadVersions(force: true)
            phase = .updated(latest)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Progress hops to the main actor to land, so a late one can arrive after the download
    /// has already finished — only advance a download that's still running.
    private func report(_ fraction: Double?) {
        guard case .downloading = phase else { return }
        phase = .downloading(fraction)
    }
}

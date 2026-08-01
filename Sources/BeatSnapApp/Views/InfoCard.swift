import AppKit
import SwiftUI

/// The "about" card: app identity, the versions of the tools BeatSnap drives, and the
/// yt-dlp update it can pull down.
///
/// Deliberately an overlay inside the panel rather than a second window — the app is an
/// accessory with a floating panel, so an extra window would need its own level and
/// activation handling to stay reachable over a DAW.
struct InfoCard: View {
    let tools: ToolStatus
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            // Same treatment as the drop overlay: blur the interface behind rather than dim
            // it, and let a click anywhere outside the card close it.
            Rectangle()
                .fill(.thinMaterial)
                .onTapGesture(perform: dismiss)

            card
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .task { await tools.loadVersions() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            identity
            Divider().opacity(0.6)
            versions
            Divider().opacity(0.6)
            updater
        }
        .frame(width: 296)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) { closeButton }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 5) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .padding(.bottom, 2)
            }
            Text("Beat Snap")
                .font(.system(size: 15, weight: .bold))
            Text(Self.appVersion)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    /// "Version 1.0.0 (1)", or just the short version when they'd read the same.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            // No Info.plist: running the executable straight out of .build.
            return "Development build"
        }
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }

    // MARK: - Tool versions

    private var versions: some View {
        VStack(spacing: 8) {
            ToolVersionRow(
                name: "yt-dlp", version: tools.ytDlpVersion, isLoading: !tools.hasReadVersions
            )
            ToolVersionRow(
                name: "ffmpeg", version: tools.ffmpegVersion, isLoading: !tools.hasReadVersions
            )
            Text("yt-dlp keeps itself current so YouTube changes don't break downloads. ffmpeg ships with the app.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Updater

    private var updater: some View {
        VStack(spacing: 9) {
            if case .downloading(let fraction) = tools.phase {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Design.bpmTint)
            }

            HStack(spacing: 8) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                AccentButton(
                    title: tools.phase.isBusy ? "Checking…" : "Check for Updates",
                    isBusy: tools.phase.isBusy,
                    isEnabled: !tools.phase.isBusy,
                    action: check
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(.easeOut(duration: 0.16), value: tools.phase)
    }

    private var isFailure: Bool {
        if case .failed = tools.phase { return true }
        return false
    }

    private var status: String {
        switch tools.phase {
        case .idle:
            if let lastChecked = tools.lastChecked {
                return "Checked \(lastChecked.formatted(.relative(presentation: .named)))"
            }
            return "Not checked yet"
        case .checking:
            return "Looking for a newer yt-dlp…"
        case .downloading(let fraction):
            guard let fraction else { return "Downloading yt-dlp…" }
            return "Downloading yt-dlp… \(Int(fraction * 100))%"
        case .upToDate:
            return "yt-dlp is up to date"
        case .updated(let version):
            return "Updated yt-dlp to \(version)"
        case .failed(let message):
            return message
        }
    }

    private func check() {
        Task { await tools.checkForUpdates() }
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Escape closes the card. As a real key equivalent it is handled before the panel's
        // own cancel handling, so it can't reach through and close the window.
        .keyboardShortcut(.cancelAction)
        .padding(6)
    }
}

private struct ToolVersionRow: View {
    let name: String
    /// nil once `isLoading` is false means the tool is there but wouldn't report a version.
    let version: String?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 0)
            if let version {
                Badge(text: version, tint: Design.keyTint)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(height: 16)
            } else {
                Text("unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

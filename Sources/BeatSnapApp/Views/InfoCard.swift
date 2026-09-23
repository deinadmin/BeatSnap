import AppKit
import SwiftUI

/// Settings and app information: analyzer preference, tool versions, and yt-dlp updates.
///
/// Deliberately an overlay inside the panel rather than a second window — the app is an
/// accessory with a floating panel, so an extra window would need its own level and
/// activation handling to stay reachable over a DAW.
struct InfoCard: View {
    private static let cardWidth: CGFloat = 296
    private static let sectionInset: CGFloat = 16

    let tools: ToolStatus
    let onKeepOnTopChanged: (Bool) -> Void
    let dismiss: () -> Void

    @State private var keepBeatSnapOnTop = AppSettings.shared.keepBeatSnapOnTop
    @State private var analysisAlgorithm = AppSettings.shared.analysisAlgorithm

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
            analyzerSettings
            Divider().opacity(0.6)
            versions
            Divider().opacity(0.6)
            updater
        }
        .frame(width: Self.cardWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) { closeButton }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    // MARK: - Analyzer settings

    private var analyzerSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Keep window on top")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Toggle("Keep window on top", isOn: $keepBeatSnapOnTop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
            }
            .onChange(of: keepBeatSnapOnTop) { _, enabled in
                AppSettings.shared.keepBeatSnapOnTop = enabled
                onKeepOnTopChanged(enabled)
            }

            analyzerPicker

            Text(analyzerDescription)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.sectionInset)
        .padding(.vertical, 14)
    }

    private var analyzerPicker: some View {
        HStack {
            Text("Algorithm")
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 8)
            Picker("Algorithm", selection: $analysisAlgorithm) {
                ForEach(AnalysisAlgorithm.allCases) { algorithm in
                    Text(algorithm.label).tag(algorithm)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .fixedSize()
            .onChange(of: analysisAlgorithm) { _, newValue in
                AppSettings.shared.analysisAlgorithm = newValue
            }
        }
    }

    private var analyzerDescription: String {
        switch analysisAlgorithm {
        case .musicUnderstanding:
            if #available(macOS 27.0, *) {
                return "Uses Apple's on-device Music Understanding framework. BeatSnap Legacy runs automatically if analysis fails."
            }
            return "Requires macOS 27. BeatSnap Legacy runs automatically on this Mac."
        case .beatSnapDSP:
            return "Uses BeatSnap's original on-device tempo and key detection algorithms."
        }
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 5) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .regular))
                .frame(width: 60, height: 60)
                .padding(.bottom, 2)
            Text("\(Text("BeatSnap").bold()) by Carlo")
                .font(.system(size: 15))
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
        VStack(alignment: .leading, spacing: 8) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                AccentButton(
                    title: tools.phase.isBusy ? "Checking…" : "Check for Updates",
                    isBusy: tools.phase.isBusy,
                    isEnabled: !tools.phase.isBusy,
                    action: check
                )
                // The status is allowed to wrap; the action label must remain complete.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
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

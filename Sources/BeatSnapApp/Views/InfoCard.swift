import AppKit
import SwiftUI

/// Settings and app information: analyzer preference, tool versions, and yt-dlp updates.
///
/// Deliberately an overlay inside the panel rather than a second window — the app is an
/// accessory with a floating panel, so an extra window would need its own level and
/// activation handling to stay reachable over a DAW.
struct InfoCard: View {
    enum Screen: Equatable {
        case activation, welcome, information
    }

    private static let cardWidth: CGFloat = 296
    private static let cardCornerRadius: CGFloat = 16
    private static let sectionInset: CGFloat = 16

    let screen: Screen
    let library: BeatLibrary
    let license: LicenseService
    let toasts: ToastCenter
    let tools: ToolStatus
    let onKeepOnTopChanged: (Bool) -> Void
    let onShortcutChanged: (WindowShortcut) -> Bool
    let onShortcutRecordingChanged: (Bool) -> Void
    let onActivated: () async -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activationFailures = 0
    @State private var isActivating = false
    @State private var licenseCode = ""
    @State private var licenseFieldFocused = false
    @State private var keepBeatSnapOnTop = AppSettings.shared.keepBeatSnapOnTop
    @State private var analysisAlgorithm = AppSettings.shared.analysisAlgorithm
    @State private var shortcut = AppSettings.shared.windowShortcut
    @State private var isRecordingShortcut = false
    @State private var shortcutMonitor: Any?
    @State private var shortcutError = false
    @State private var confirmingLicenseRemoval = false
    // Cursor geometry is deliberately not observable: animation frames must not
    // invalidate the SwiftUI tree that is currently calculating those frames.
    @State private var cursorGeometry = BackdropArrowCursor.Geometry()

    private var morphAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.15 : 0.5)
    }

    var body: some View {
        ZStack {
            // Same treatment as the drop overlay: blur the interface behind rather than dim
            // it. A click outside the card closes settings; activation stays up until a
            // license is entered.
            Rectangle()
                .fill(.thinMaterial)
                .contentShape(Rectangle())
                .pointerStyle(.default)
                .onTapGesture { if screen == .information { dismiss() } }
                .overlay {
                    // The URL field behind this blur keeps its I-beam cursor rect. This
                    // layer is the hit target for the backdrop, so the pointer stays the
                    // arrow there; the card is passed through.
                    BackdropArrowCursor(
                        geometry: cursorGeometry,
                        cornerRadius: Self.cardCornerRadius,
                        onClick: screen == .information ? dismiss : nil
                    )
                }

            card
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("infoBackdrop")) } action: {
                    cursorGeometry.cardFrame = $0
                }
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .coordinateSpace(.named("infoBackdrop"))
        .task(id: screen) {
            if screen == .information { await tools.loadVersions() }
            else if screen == .activation {
                try? await Task.sleep(for: .seconds(reduceMotion ? 0.15 : 0.5))
                guard !Task.isCancelled else { return }
                licenseFieldFocused = true
            }
        }
        .onChange(of: license.isLicensed) { _, licensed in
            if !licensed { stopRecordingShortcut() }
        }
        .onDisappear { stopRecordingShortcut() }
        .alert("Are you sure?", isPresented: $confirmingLicenseRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove License", role: .destructive) {
                Task { await license.removeLicense() }
            }
        } message: {
            Text("This license will be removed from this Mac.")
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            identity
            Divider().opacity(0.6)
            ZStack(alignment: .top) {
                switch screen {
                case .information:
                    VStack(spacing: 0) {
                        licenseInformation
                        Divider().opacity(0.6)
                        analyzerSettings
                        Divider().opacity(0.6)
                        versions
                        Divider().opacity(0.6)
                        updater
                    }
                    .transition(.opacity)
                case .activation:
                    activation
                        .transition(.opacity)
                case .welcome:
                    welcome
                        .transition(.opacity)
                }
            }
            .clipped()
        }
        .frame(width: Self.cardWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cardCornerRadius))
        // The glass fills the card, but gaps between sections would otherwise fall through
        // to the dismiss target behind it.
        .contentShape(.rect(cornerRadius: Self.cardCornerRadius))
        .overlay(alignment: .topTrailing) {
            closeButton
                .opacity(screen == .information ? 1 : 0)
                .allowsHitTesting(screen == .information)
                .accessibilityHidden(screen != .information)
                .animation(morphAnimation, value: screen)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .animation(reduceMotion ? nil : morphAnimation, value: screen)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: activationFailures) { [reduceMotion] card, offset in
            card.offset(x: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            LinearKeyframe(-7, duration: 0.06)
            LinearKeyframe(7, duration: 0.06)
            LinearKeyframe(-5, duration: 0.06)
            LinearKeyframe(5, duration: 0.06)
            LinearKeyframe(0, duration: 0.08)
        }
    }

    private var activation: some View {
        VStack(spacing: 12) {
            LicenseCodeField(text: $licenseCode, isFocused: $licenseFieldFocused,
                             isEnabled: !license.isLicensed && !license.isBusy, onSubmit: activate)
                .frame(height: 16)
                .padding(10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("License code")
            AccentButton(
                title: isActivating || license.isBusy ? "Verifying…" : "Activate BeatSnap",
                isBusy: isActivating || license.isBusy,
                isEnabled: !isActivating && !license.isBusy && LicenseCodeInput.isComplete(licenseCode),
                action: activate
            )
        }
        .padding(Self.sectionInset)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to BeatSnap!")
                    .font(.system(size: 15, weight: .semibold))
                Text("Choose where your beats live and make BeatSnap feel right at home.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Self.sectionInset)

            Divider().opacity(0.6)

            analyzerSettings
            Divider().opacity(0.6)

            Button(action: dismiss) {
                Text("Start using BeatSnap")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Design.bpmTint)
            .padding(Self.sectionInset)
        }
    }

    private func activate() {
        guard !isActivating, !license.isBusy,
              LicenseCodeInput.isComplete(licenseCode) else { return }
        isActivating = true
        Task {
            defer { isActivating = false }
            await license.activate(licenseCode)
            if license.isLicensed {
                licenseFieldFocused = false
                toasts.clear()
                await onActivated()
                return
            }
            guard let message = license.message else { return }
            // Keep the original input so a typo can be corrected without retyping the key.
            licenseFieldFocused = true
            activationFailures += 1
            toasts.show(.error, title: "Could not activate BeatSnap", message: message)
        }
    }

    private var licenseInformation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("License")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
                licensePreview
            }
            HStack(spacing: 8) {
                licenseExpiry
                Spacer(minLength: 2)
                Button(license.isBusy ? "Please wait…" : "Remove License", role: .destructive) {
                    confirmingLicenseRemoval = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(license.isBusy)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
            licenseMessage
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Self.sectionInset)

    }

    @ViewBuilder
    private var licensePreview: some View {
        if license.isTestLicense {
            Text("XXXXX–XXXXX–XXXXX–XXXXX–" + (license.isTrialMode ? "TRIAL" : "CARLO"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        } else if let certificate = license.certificate {
            Text("XXXXX–XXXXX–XXXXX–XXXXX–" + certificate.key.suffix(5))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var licenseExpiry: some View {
        if license.isTestLicense {
            Text(license.isTrialMode ? "Trial test license (10 beats)" : "Test license (No expiry)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else if let certificate = license.certificate {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let days = max(0, Int(ceil(certificate.expiration.timeIntervalSince(context.date) / 86400)))
                Text(days == 1 ? "Expires in 1 day" : "Expires in \(days) days")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var licenseMessage: some View {
        if let message = license.message {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("License status: " + message)
        }
    }

    // MARK: - Analyzer settings

    private var analyzerSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            BeatsFolderPicker(path: library.downloadFolderPath) {
                library.chooseDownloadFolder()
            }

            HStack(spacing: 8) {
                Text("Shortcut")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Button(isRecordingShortcut ? "Press shortcut…" :
                       shortcutError ? "Unavailable — retry" : shortcut.label) {
                    if isRecordingShortcut { stopRecordingShortcut() }
                    else { startRecordingShortcut() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Set the shortcut to show or hide the BeatSnap window")
                .accessibilityLabel("Show or hide BeatSnap shortcut")
                .accessibilityValue(isRecordingShortcut ? "Waiting for shortcut" : shortcut.label)
            }

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

    private func startRecordingShortcut() {
        shortcutError = false
        isRecordingShortcut = true
        onShortcutRecordingChanged(true)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels recording.
                stopRecordingShortcut()
                return nil
            }
            guard let candidate = WindowShortcut(event: event) else { return nil }
            shortcutError = !onShortcutChanged(candidate)
            if !shortcutError { shortcut = candidate }
            stopRecordingShortcut()
            return nil
        }
    }

    private func stopRecordingShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        onShortcutRecordingChanged(false)
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
            .controlSize(.small)
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

private struct BeatsFolderPicker: View {
    let path: String
    let chooseFolder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Beats folder")
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize()
            Spacer(minLength: 8)
            Button(action: chooseFolder) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(path + "\nChoose a different beats folder")
            .accessibilityLabel("Choose beats folder")
            .accessibilityValue(path)
            .accessibilityHint("Opens the folder chooser")
        }
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
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

/// The URL field behind the blur keeps an I-beam cursor rect, and a SwiftUI overlay does not
/// replace it. This view owns the arrow for everything outside the card, and leaves the card
/// — including the activation field — to set its own pointer.
private struct BackdropArrowCursor: NSViewRepresentable {
    final class Geometry {
        weak var view: CursorView?
        var cardFrame: CGRect = .zero {
            didSet { view?.swiftUICardFrame = cardFrame }
        }
    }

    let geometry: Geometry
    var cornerRadius: CGFloat
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        view.cornerRadius = cornerRadius
        view.swiftUICardFrame = geometry.cardFrame
        view.onClick = onClick
        geometry.view = view
        return view
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cornerRadius = cornerRadius
        view.onClick = onClick
        if view.swiftUICardFrame != geometry.cardFrame {
            view.swiftUICardFrame = geometry.cardFrame
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CursorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class CursorView: NSView {
        var cornerRadius: CGFloat = 16
        var onClick: (() -> Void)?
        var swiftUICardFrame: CGRect = .zero {
            didSet {
                guard swiftUICardFrame != oldValue else { return }
                updateTrackingAreas()
                window?.invalidateCursorRects(for: self)
            }
        }

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard superview != nil else { return nil }
            let local = convert(point, from: superview)
            // Until the card frame is known, claim nothing — otherwise this layer covers
            // the card and steals its clicks.
            guard bounds.contains(local), cardFrameInView.width > 0, !isOverCard(local) else { return nil }
            return self
        }

        private var laidOutBounds: CGRect = .null

        override func layout() {
            super.layout()
            guard laidOutBounds != bounds else { return }
            laidOutBounds = bounds
            // The card frame often arrives before this view has a size. Tracking areas added
            // then are empty, so rebuild them once the backdrop has real bounds.
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            for region in backdropRegions {
                addCursorRect(region, cursor: .arrow)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            for region in backdropRegions {
                addTrackingArea(NSTrackingArea(
                    rect: region,
                    options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited],
                    owner: self,
                    userInfo: nil
                ))
            }
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local), !isOverCard(local) else { return }
            onClick?()
        }

        /// SwiftUI reports the card from the top left; AppKit cursor rects grow from the bottom left.
        private var cardFrameInView: CGRect {
            guard swiftUICardFrame.width > 0, swiftUICardFrame.height > 0, bounds.height > 0 else {
                return .zero
            }
            return CGRect(
                x: swiftUICardFrame.minX,
                y: bounds.height - swiftUICardFrame.maxY,
                width: swiftUICardFrame.width,
                height: swiftUICardFrame.height
            )
        }

        private func isOverCard(_ point: CGPoint) -> Bool {
            let frame = cardFrameInView
            guard frame.width > 0, frame.height > 0 else { return false }
            return NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius).contains(point)
        }

        /// The blur split into the four rectangles around the card. Cursor rects are rectangular,
        /// so the card is left as a hole rather than covered by the arrow.
        private var backdropRegions: [CGRect] {
            let hole = cardFrameInView
            guard hole.width > 0, hole.height > 0, bounds.width > 0, bounds.height > 0 else { return [] }
            return [
                CGRect(x: bounds.minX, y: hole.maxY, width: bounds.width, height: bounds.maxY - hole.maxY),
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: hole.minY - bounds.minY),
                CGRect(x: bounds.minX, y: hole.minY, width: hole.minX - bounds.minX, height: hole.height),
                CGRect(x: hole.maxX, y: hole.minY, width: bounds.maxX - hole.maxX, height: hole.height),
            ].filter { $0.width > 0.5 && $0.height > 0.5 }
        }
    }
}

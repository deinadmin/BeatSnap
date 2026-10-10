import SwiftUI

enum BeatLabelEditorScope: String, Identifiable {
    case all
    case bpm
    case key

    var id: Self { self }
}

/// A compact label editor presented from a finished beat row. It intentionally owns its
/// draft locally: dismissing the popover is a true cancel and never mutates the library.
struct BeatLabelEditor: View {
    let beat: Beat
    let scope: BeatLabelEditorScope

    @Environment(BeatLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var bpmText: String
    @State private var tonic: String
    @State private var mode: BeatKey.Mode
    @State private var isAnalyzing = false
    @FocusState private var bpmFocused: Bool

    init(beat: Beat, scope: BeatLabelEditorScope = .all) {
        self.beat = beat
        self.scope = scope
        let key = BeatKey(displayName: beat.key) ?? BeatKey(tonic: "A", mode: .minor)
        _bpmText = State(initialValue: String(beat.bpm))
        _tonic = State(initialValue: key.tonic)
        _mode = State(initialValue: key.mode)
    }

    private var bpm: Int? {
        guard let value = Int(bpmText), (1...999).contains(value) else { return nil }
        return value
    }

    /// Halving only applies to even tempos; an odd BPM would round and mislabel the beat.
    private var canHalve: Bool {
        guard let bpm else { return false }
        return bpm.isMultiple(of: 2) && bpm / 2 >= 1
    }

    /// Doubling must stay within the 999 BPM limit (so 499 → 998 is the highest).
    private var canDouble: Bool {
        guard let bpm else { return false }
        return bpm * 2 <= 999
    }

    private var selectedKey: BeatKey { BeatKey(tonic: tonic, mode: mode) }

    private var editorTint: Color { scope == .key ? Design.keyTint : Design.bpmTint }

    private var hasChanges: Bool {
        switch scope {
        case .all: bpm != beat.bpm || selectedKey.displayName != beat.key
        case .bpm: bpm != beat.bpm
        case .key: selectedKey.displayName != beat.key
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if scope != .key { bpmEditor.disabled(isAnalyzing) }
            if scope != .bpm { keyEditor.disabled(isAnalyzing) }

            footer
        }
        .padding(16)
        .frame(width: scope == .bpm ? 280 : 316)
        .interactiveDismissDisabled(isAnalyzing)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(editorTint)
                .frame(width: 34, height: 34)
                .glassEffect(
                    .regular.tint(editorTint.opacity(0.18)),
                    in: .rect(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Edit analysis")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Updates the label, audio stays untouched.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bpmEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("TEMPO", tint: Design.bpmTint)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ValueButton(systemName: "minus", tint: Design.bpmTint) { nudgeBPM(by: -1) }

                    // NSTextField can't animate its text, so a Text mirrors the value while the
                    // field isn't being edited: typing stays instant, buttons roll the digits.
                    ZStack {
                        Text(bpmText)
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(bpm ?? 0)))
                            .opacity(bpmFocused ? 0 : 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)

                        TextField("BPM", text: $bpmText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .focused($bpmFocused)
                            .opacity(bpmFocused ? 1 : 0)
                            .onChange(of: bpmText) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(3))
                                if digits != newValue { bpmText = digits }
                            }
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { bpmFocused = true }
                        .background(Design.bpmTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Design.bpmTint.opacity(bpmFocused ? 0.65 : 0.24))
                        }
                        .accessibilityLabel("BPM")

                    ValueButton(systemName: "plus", tint: Design.bpmTint) { nudgeBPM(by: 1) }

                    VStack(spacing: 5) {
                        RatioButton(title: "½×", isEnabled: canHalve) { scaleBPM(by: 0.5) }
                        RatioButton(title: "2×", isEnabled: canDouble) { scaleBPM(by: 2) }
                    }
                }
            }
        }
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("KEY", tint: Design.keyTint)
                relativeButton
                Spacer()
                modePicker
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                ForEach(BeatKey.tonics, id: \.self) { candidate in
                    Button {
                        withAnimation(.easeOut(duration: 0.1)) { tonic = candidate }
                    } label: {
                        Text(candidate)
                            .font(.system(size: 11.5, weight: tonic == candidate ? .bold : .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 27)
                            .animation(.snappy(duration: 0.3), value: tonic)
                            .foregroundStyle(tonic == candidate ? Color.white : Design.keyTint)
                            .background(
                                tonic == candidate ? Design.keyTint : Design.keyTint.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Design.keyTint.opacity(tonic == candidate ? 0 : 0.18))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Key \(candidate)")
                    .accessibilityAddTraits(tonic == candidate ? .isSelected : [])
                }
            }
        }
    }

    /// Jumps to the relative key (C major ⇄ A minor). The label previews where it will land.
    private var relativeButton: some View {
        let target = selectedKey.relative
        return Button {
            withAnimation(.snappy(duration: 0.28)) {
                tonic = target.tonic
                mode = target.mode
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                Text(target.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Design.keyTint)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .help("Switch to the relative key, \(target.displayName)")
        .accessibilityLabel("Switch to relative key \(target.displayName)")
    }

    private var modePicker: some View {
        ModeSwitch(mode: $mode)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await analyzeBeat() }
                } label: {
                    HStack(spacing: 5) {
                        if isAnalyzing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        Text("Analyse")
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(isAnalyzing)

                Spacer(minLength: 6)

                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAnalyzing)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(editorTint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAnalyzing || (scope != .key && bpm == nil) || !hasChanges)
            }
        }
    }

    private func sectionLabel(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(tint)
    }

    private func nudgeBPM(by amount: Int) {
        bpmFocused = false
        let current = bpm ?? beat.bpm
        withAnimation(.snappy(duration: 0.3)) {
            bpmText = String(min(999, max(1, current + amount)))
        }
    }

    private func scaleBPM(by ratio: Double) {
        guard let current = bpm else { return }
        let scaled = ratio < 1 ? current / 2 : current * 2
        guard ratio < 1 ? canHalve : canDouble else { return }
        bpmFocused = false
        withAnimation(.snappy(duration: 0.3)) {
            bpmText = String(scaled)
        }
    }

    private func save() {
        guard !isAnalyzing, hasChanges else { return }
        let savedBPM: Int
        if scope == .key {
            savedBPM = beat.bpm
        } else {
            guard let bpm else { return }
            savedBPM = bpm
        }
        let savedKey = scope == .bpm
            ? (BeatKey(displayName: beat.key) ?? selectedKey)
            : selectedKey

        do {
            try library.updateLabels(for: beat, bpm: savedBPM, key: savedKey)
            dismiss()
        } catch {
            library.toasts.report(error, title: "Could not update tags")
        }
    }

    @MainActor
    private func analyzeBeat() async {
        guard !isAnalyzing else { return }
        bpmFocused = false
        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            let result = try await library.reanalyzeLabels(for: beat)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.3)) {
                if scope != .key { bpmText = String(result.bpm) }
                if scope != .bpm {
                    tonic = result.key.tonic
                    mode = result.key.mode
                }
            }
        } catch is CancellationError {
            return
        } catch {
            library.toasts.report(error, title: "Could not analyze the beat")
        }
    }
}

private struct ValueButton: View {
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }
}

private struct RatioButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 10)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
}

/// Major/Minor switch with a sliding thumb, so programmatic changes (like the relative-key
/// button) animate exactly like a tap instead of snapping.
private struct ModeSwitch: View {
    @Binding var mode: BeatKey.Mode
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BeatKey.Mode.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.28)) { mode = option }
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(mode == option ? Color.white : Design.keyTint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if mode == option {
                                Capsule()
                                    .fill(Design.keyTint)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Design.keyTint.opacity(0.11), in: .capsule)
        .overlay { Capsule().strokeBorder(Design.keyTint.opacity(0.18)) }
        .frame(width: 142)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }
}

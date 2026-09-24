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

                    TextField("BPM", text: $bpmText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .focused($bpmFocused)
                        .onChange(of: bpmText) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(3))
                            if digits != newValue { bpmText = digits }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Design.bpmTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Design.bpmTint.opacity(bpmFocused ? 0.65 : 0.24))
                        }
                        .accessibilityLabel("BPM")

                    ValueButton(systemName: "plus", tint: Design.bpmTint) { nudgeBPM(by: 1) }

                    VStack(spacing: 5) {
                        RatioButton(title: "½×") { scaleBPM(by: 0.5) }
                        RatioButton(title: "2×") { scaleBPM(by: 2) }
                    }
                }
            }
        }
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("KEY", tint: Design.keyTint)
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

    @ViewBuilder
    private var modePicker: some View {
        if #available(macOS 27.0, *) {
            modePickerContent
                .pickerStyle(.tabs)
        } else {
            modePickerContent
                .pickerStyle(.segmented)
        }
    }

    private var modePickerContent: some View {
        Picker("Mode", selection: $mode) {
            ForEach(BeatKey.Mode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .labelsHidden()
        .tint(Design.keyTint)
        .controlSize(.large)
        .frame(width: 142)
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
        let current = bpm ?? beat.bpm
        bpmText = String(min(999, max(1, current + amount)))
    }

    private func scaleBPM(by ratio: Double) {
        let current = bpm ?? beat.bpm
        bpmText = String(min(999, max(1, Int((Double(current) * ratio).rounded()))))
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
            if scope != .key { bpmText = String(result.bpm) }
            if scope != .bpm {
                tonic = result.key.tonic
                mode = result.key.mode
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
    }
}

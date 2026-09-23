import SwiftUI

/// Shared colours, metrics and small building blocks for the BeatSnap UI.
enum Design {
    static let rowCorner: CGFloat = 9
    static let tileSize: CGFloat = 36
    /// Inset from the window edges for header and download-bar content.
    ///
    /// Chosen to equal the header button's vertical inset: `.buttonStyle(.glass)` grows a
    /// 20pt icon to a 28pt footprint, which the 52pt band centres with (52-28)/2 = 12pt
    /// above it. Matching the horizontal inset keeps the button equidistant from the top
    /// and right edges, and lines its right edge up with the Download button below.
    static let panelPadding: CGFloat = 12
    /// Icon frame inside the header's circular glass button.
    static let headerIconSize: CGFloat = 20
    /// Height of the band the traffic lights sit in. They are centred 26pt below the
    /// window top, so a 52pt band centres header content on the same line.
    static let titlebarBand: CGFloat = 52

    static let bpmTint = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let keyTint = Color(red: 0.60, green: 0.30, blue: 0.95)
}

/// A small tinted capsule, used for BPM and key.
struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Circular icon button used in the header.
struct CircleIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: Design.headerIconSize, height: Design.headerIconSize)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
    }
}

/// Borderless icon button revealed on row hover.
struct RowIconButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(role == .destructive && isHovering ? Color.red : Color.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(isHovering ? 0.9 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Accent pill button (the Download action).
struct AccentButton: View {
    let title: String
    var isBusy = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Design.bpmTint)
        .disabled(!isEnabled)
    }
}

struct TwoToneSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var label = "Downloading"

    var body: some View {
        ZStack {
            Circle().stroke(Design.bpmTint.opacity(0.22), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Design.bpmTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotating && !reduceMotion ? 270 : -90))
                .animation(reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false),
                           value: rotating)
        }
        .frame(width: 15, height: 15)
        .onAppear { rotating = true }
        .accessibilityLabel(label)
    }
}

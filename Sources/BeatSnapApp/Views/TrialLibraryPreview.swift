import SwiftUI

/// Decorative previews only: no playback, drag, download, or editing controls.
struct TrialLibraryPreview: View {
    let beats: [Beat]

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                // Keep a three-row backdrop even when only one or two beats are hidden.
                ForEach(0..<3, id: \.self) { slot in
                    previewRow(slot < beats.count ? beats[slot] : nil)
                }
            }
            .blur(radius: 5)
            .opacity(0.55)
            .mask {
                LinearGradient(colors: [.black, .black.opacity(0.25)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text("BeatSnap is in Trial Mode")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Provide a full license to view all of your beats and enjoy unlimited downloads.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(18)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    private func previewRow(_ beat: Beat?) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "music.note")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: Design.tileSize, height: Design.tileSize)
                .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: Design.tileCorner))
            VStack(alignment: .leading, spacing: 4) {
                Text(beat?.title ?? "More beats in your library")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Badge(text: "\(beat?.bpm ?? 140) BPM", tint: Design.bpmTint)
                    Badge(text: beat?.key ?? "A minor", tint: Design.keyTint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Design.rowContentHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

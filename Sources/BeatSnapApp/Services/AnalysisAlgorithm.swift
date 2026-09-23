import AVFoundation
import BeatSnapAnalysis
import Foundation

#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

enum AnalysisAlgorithm: String, CaseIterable, Identifiable {
    case musicUnderstanding
    case beatSnapDSP

    var id: Self { self }

    var label: String {
        switch self {
        case .musicUnderstanding: "Apple"
        case .beatSnapDSP: "BeatSnap Legacy"
        }
    }
}

/// Chooses between Apple's system analyzer and BeatSnap's original DSP implementation.
///
/// Music Understanding is intentionally wrapped here rather than in BeatSnapAnalysis: the
/// development CLI continues to measure the custom DSP against its existing reference set,
/// and the app can weak-link the new framework while retaining macOS 26 compatibility.
struct AppAudioAnalyzer: Sendable {
    private let fallback = BeatAnalyzer()

    func analyze(url: URL, preferred algorithm: AnalysisAlgorithm) async throws -> AnalysisResult {
        switch algorithm {
        case .beatSnapDSP:
            return try await analyzeWithFallback(url: url)
        case .musicUnderstanding:
            do {
                return try await analyzeWithMusicUnderstanding(url: url)
            } catch {
                // The system framework may be unavailable, reject an asset, or return no
                // global tempo/key. None of those should prevent a beat from being imported.
                return try await analyzeWithFallback(url: url)
            }
        }
    }

    private func analyzeWithFallback(url: URL) async throws -> AnalysisResult {
        let fallback = self.fallback
        return try await Task.detached(priority: .userInitiated) {
            try fallback.analyze(url: url)
        }.value
    }

    private func analyzeWithMusicUnderstanding(url: URL) async throws -> AnalysisResult {
#if canImport(MusicUnderstanding)
        guard #available(macOS 27.0, *) else {
            throw AnalyzerError.musicUnderstandingUnavailable
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await session.analyze(for: [.rhythm, .key])

        guard let rawBPM = result.rhythm?.beatsPerMinute,
              rawBPM.isFinite,
              rawBPM > 0,
              let signature = result.key?.ranges.max(by: {
                  $0.range.duration.seconds < $1.range.duration.seconds
              })?.value
        else {
            throw AnalyzerError.incompleteMusicUnderstandingResult
        }

        let tonic = Self.name(for: signature.tonic)
        let mode = signature.mode == .major ? "major" : "minor"
        let modeShort = signature.mode == .major ? "maj" : "min"
        let duration = try? await asset.load(.duration)

        return AnalysisResult(
            bpm: Int(rawBPM.rounded()),
            key: "\(tonic) \(mode)",
            keyShort: "\(tonic)\(modeShort)",
            // Music Understanding doesn't expose confidence values. These fields are used
            // only by the custom analyzer's development CLI, not by the app.
            tempoConfidence: 0,
            keyStrength: 0,
            analyzedSeconds: duration?.seconds ?? 0
        )
#else
        throw AnalyzerError.musicUnderstandingUnavailable
#endif
    }

#if canImport(MusicUnderstanding)
    @available(macOS 27.0, *)
    private static func name(for tonic: MusicUnderstanding.KeyResult.Tonic) -> String {
        // Preserve BeatSnap's A-referenced spelling so filenames and the existing library
        // continue to use Bb/Eb/Ab rather than their sharp enharmonic equivalents.
        switch tonic {
        case .a: "A"
        case .aFlat, .gSharp: "Ab"
        case .aSharp, .bFlat: "Bb"
        case .b: "B"
        case .c: "C"
        case .cSharp, .dFlat: "C#"
        case .d: "D"
        case .dSharp, .eFlat: "Eb"
        case .e: "E"
        case .f: "F"
        case .fSharp, .gFlat: "F#"
        case .g: "G"
        }
    }
#endif
}

private enum AnalyzerError: Error {
    case musicUnderstandingUnavailable
    case incompleteMusicUnderstandingResult
}

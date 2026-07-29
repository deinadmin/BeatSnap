import BeatSnapAnalysis
import Foundation

/// Diagnostics for the key pipeline: shows whether peaks are being found and what the
/// chromagram actually looks like before it reaches the profile correlation.
enum DebugProbe {
    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            let audio = try AudioDecoder.decodeMono(url: url, sampleRate: 44100, maxSeconds: 180)
            print("file: \(url.lastPathComponent)")
            print(
                String(
                    format: "decoded: %d samples, %.1fs @ %.0f Hz",
                    audio.samples.count, audio.durationSec, audio.sampleRate
                )
            )
            let peak = audio.samples.map { abs($0) }.max() ?? 0
            let rms = (audio.samples.reduce(0) { $0 + $1 * $1 } / Float(audio.samples.count)).squareRoot()
            print(String(format: "signal: peak %.4f, rms %.4f", peak, rms))

            let stats = KeyDetector.debugStats(
                samples: audio.samples,
                sampleRate: audio.sampleRate,
                config: KeyDetectorConfig()
            )
            print("frames: \(stats.frames), frames with peaks: \(stats.framesWithPeaks)")
            print(String(format: "spectrum max (first frame): %.4f", stats.firstFrameSpectrumMax))
            print("peaks in first frame: \(stats.firstFramePeakCount)")
            print(String(format: "avg peaks/frame: %.1f", stats.averagePeaks))
            print(
                String(
                    format: "whitened magnitude range: %.6f … %.6f",
                    stats.minWhitenedMagnitude, stats.maxWhitenedMagnitude
                )
            )

            let names = ["A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"]
            print("raw chroma:")
            for (i, value) in stats.rawChroma.enumerated() {
                print(String(format: "  %-3@ %.6e", names[i] as NSString, value))
            }
            print("gated chroma:")
            for (i, value) in stats.gatedChroma.enumerated() {
                print(String(format: "  %-3@ %.4f", names[i] as NSString, value))
            }

            let result = KeyDetector.detect(
                samples: audio.samples, sampleRate: audio.sampleRate, config: KeyDetectorConfig()
            )
            print("=> \(result.name)  (strength \(String(format: "%.3f", result.strength)))")
        } catch {
            print("ERROR: \(error)")
        }
    }
}

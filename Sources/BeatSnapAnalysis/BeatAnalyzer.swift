import Foundation

public struct AnalysisResult: Sendable {
    public let bpm: Int
    /// Full key name, e.g. "F# minor".
    public let key: String
    /// Filename-safe short key, e.g. "F#min".
    public let keyShort: String
    public let tempoConfidence: Double
    public let keyStrength: Double
    /// Seconds of audio actually analysed.
    public let analyzedSeconds: Double
}

/// On-device BPM + musical key analysis. Decodes with AVFoundation and runs entirely
/// locally — no network, no external binaries.
public struct BeatAnalyzer: Sendable {
    public var sampleRate: Double
    public var maxSeconds: Double
    public var tempo: TempoConfig
    public var key: KeyDetectorConfig

    public init(
        sampleRate: Double = 44100,
        maxSeconds: Double = 180,
        tempo: TempoConfig = TempoConfig(),
        key: KeyDetectorConfig = KeyDetectorConfig()
    ) {
        self.sampleRate = sampleRate
        self.maxSeconds = maxSeconds
        self.tempo = tempo
        self.key = key
    }

    public func analyze(url: URL) throws -> AnalysisResult {
        let audio = try AudioDecoder.decodeMono(
            url: url,
            sampleRate: sampleRate,
            maxSeconds: maxSeconds
        )
        return analyze(audio: audio)
    }

    public func analyze(audio: DecodedAudio) -> AnalysisResult {
        let tempoResult = TempoDetector.detect(
            samples: audio.samples,
            sampleRate: audio.sampleRate,
            config: tempo
        )
        let keyResult = KeyDetector.detect(
            samples: audio.samples,
            sampleRate: audio.sampleRate,
            config: key
        )
        return AnalysisResult(
            bpm: tempoResult.roundedBPM,
            key: keyResult.name,
            keyShort: keyResult.shortName,
            tempoConfidence: tempoResult.confidence,
            keyStrength: keyResult.strength,
            analyzedSeconds: audio.durationSec
        )
    }
}

import Foundation

public struct KeyResult: Sendable {
    /// Tonic name, e.g. "F#". Uses the A-referenced naming convention (Ab, not G#).
    public let tonic: String
    /// "major" or "minor".
    public let scale: String
    /// Correlation strength of the winning profile, 0...1.
    public let strength: Double

    /// Display form, e.g. "F# minor".
    public var name: String { "\(tonic) \(scale)" }
    /// Filename-safe short form, e.g. "F#min".
    public var shortName: String { "\(tonic)\(scale == "minor" ? "min" : "maj")" }
}

/// Key profiles: relative weights for each pitch class of a major/minor scale, indexed from
/// the tonic. Correlating a chromagram against all 24 rotations picks the key.
public enum KeyProfile: String, Sendable, CaseIterable {
    /// Median profiles from a large electronic/dance corpus with the least relevant
    /// degrees zeroed (Faraldo et al., 2017). Best performer on produced beats.
    case bgate
    /// The same corpus medians without zeroing (Faraldo et al., 2017).
    case braw
    /// Corpus-derived electronic dance music profiles (Faraldo et al., 2016).
    case edma
    /// Krumhansl's profiles tuned for popular/electronic music (Shaath).
    case shaath
    /// Krumhansl-Schmuckler probe-tone profiles.
    case krumhansl
    /// Temperley's revision of the Krumhansl-Schmuckler profiles.
    case temperley

    var major: [Float] {
        switch self {
        case .bgate:
            [1.00, 0.00, 0.42, 0.00, 0.53, 0.37, 0.00, 0.77, 0.00, 0.38, 0.21, 0.30]
        case .braw:
            [1.0000, 0.1573, 0.4200, 0.1570, 0.5296, 0.3669, 0.1632, 0.7711, 0.1676, 0.3827, 0.2113, 0.2965]
        case .edma:
            [1.00, 0.29, 0.50, 0.40, 0.60, 0.56, 0.32, 0.80, 0.31, 0.45, 0.42, 0.39]
        case .shaath:
            [6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4]
        case .krumhansl:
            [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        case .temperley:
            [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]
        }
    }

    var minor: [Float] {
        switch self {
        case .bgate:
            [1.00, 0.00, 0.36, 0.39, 0.00, 0.38, 0.00, 0.74, 0.27, 0.00, 0.42, 0.23]
        case .braw:
            [1.0000, 0.2330, 0.3615, 0.3905, 0.2925, 0.3777, 0.1961, 0.7425, 0.2701, 0.2161, 0.4228, 0.2272]
        case .edma:
            [1.00, 0.31, 0.44, 0.58, 0.33, 0.49, 0.29, 0.78, 0.43, 0.29, 0.53, 0.32]
        case .shaath:
            [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]
        case .krumhansl:
            [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        case .temperley:
            [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0]
        }
    }
}

public struct KeyDetectorConfig: Sendable {
    public var frameSize = 4096
    public var hopSize = 4096
    public var minFrequency: Float = 25
    public var maxFrequency: Float = 3500
    public var peakThreshold: Float = 0.0001
    public var maxPeaks = 60
    public var referenceFrequency: Float = 440
    public var pcpThreshold: Float = 0.2
    public var harmonics = 4
    public var profile: KeyProfile = .bgate
    public var useWhitening = true

    public init() {}
}

public enum KeyDetector {
    /// Pitch class names indexed from the reference frequency (440 Hz = A), matching the
    /// naming used by the original BeatSnap library (so "Ab minor", never "G# minor").
    static let pitchNames = ["A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"]

    public static func detect(
        samples: [Float],
        sampleRate: Double,
        config: KeyDetectorConfig = KeyDetectorConfig()
    ) -> KeyResult {
        let chroma = chromagram(samples: samples, sampleRate: sampleRate, config: config)
        return classify(chroma: chroma, config: config)
    }

    public struct DebugStats: Sendable {
        public var frames = 0
        public var framesWithPeaks = 0
        public var firstFrameSpectrumMax: Float = 0
        public var firstFramePeakCount = 0
        public var averagePeaks: Double = 0
        public var minWhitenedMagnitude: Float = 0
        public var maxWhitenedMagnitude: Float = 0
        public var rawChroma = [Float](repeating: 0, count: 12)
        public var gatedChroma = [Float](repeating: 0, count: 12)
    }

    /// Instrumented run of the key pipeline, used to diagnose the stage where a chromagram
    /// stops carrying information.
    public static func debugStats(
        samples: [Float],
        sampleRate: Double,
        config: KeyDetectorConfig
    ) -> DebugStats {
        var stats = DebugStats()
        let frameSize = config.frameSize
        let fft = RealFFT(n: frameSize)
        let window = Windows.hann(frameSize)
        let hpcp = HPCP(
            size: 12,
            harmonics: config.harmonics,
            referenceFrequency: config.referenceFrequency,
            minFrequency: config.minFrequency,
            maxFrequency: config.maxFrequency
        )

        var accumulated = [Float](repeating: 0, count: 12)
        var totalPeaks = 0
        stats.minWhitenedMagnitude = .greatestFiniteMagnitude
        stats.maxWhitenedMagnitude = -.greatestFiniteMagnitude

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset + frameSize <= samples.count {
                let spectrum = fft.magnitudeSpectrum(frame: base + offset, window: window)
                var peaks = SpectralPeaks.detect(
                    spectrum: spectrum,
                    sampleRate: sampleRate,
                    minFrequency: config.minFrequency,
                    maxFrequency: config.maxFrequency,
                    magnitudeThreshold: config.peakThreshold,
                    maxPeaks: config.maxPeaks
                )
                if stats.frames == 0 {
                    stats.firstFrameSpectrumMax = spectrum.max() ?? 0
                    stats.firstFramePeakCount = peaks.count
                }
                if config.useWhitening {
                    peaks = SpectralWhitening.whiten(
                        peaks: peaks,
                        spectrum: spectrum,
                        sampleRate: sampleRate,
                        maxFrequency: config.maxFrequency
                    )
                }
                for peak in peaks {
                    stats.minWhitenedMagnitude = min(stats.minWhitenedMagnitude, peak.magnitude)
                    stats.maxWhitenedMagnitude = max(stats.maxWhitenedMagnitude, peak.magnitude)
                }
                totalPeaks += peaks.count
                if !peaks.isEmpty {
                    var frameProfile = [Float](repeating: 0, count: 12)
                    hpcp.accumulate(peaks: peaks, into: &frameProfile)
                    for i in 0..<12 { accumulated[i] += frameProfile[i] }
                    stats.framesWithPeaks += 1
                }
                stats.frames += 1
                offset += config.hopSize
            }
        }

        if stats.framesWithPeaks > 0 {
            for i in 0..<12 { accumulated[i] /= Float(stats.framesWithPeaks) }
        }
        stats.rawChroma = accumulated
        stats.averagePeaks = stats.frames > 0 ? Double(totalPeaks) / Double(stats.frames) : 0

        var gated = accumulated
        if let peak = gated.max(), peak > 0 {
            for i in 0..<12 {
                gated[i] /= peak
                if gated[i] < config.pcpThreshold { gated[i] = 0 }
            }
        }
        stats.gatedChroma = gated
        if stats.minWhitenedMagnitude == .greatestFiniteMagnitude { stats.minWhitenedMagnitude = 0 }
        if stats.maxWhitenedMagnitude == -.greatestFiniteMagnitude { stats.maxWhitenedMagnitude = 0 }
        return stats
    }

    /// Averaged, peak-normalised and gated 12-bin chromagram for the whole signal.
    static func chromagram(
        samples: [Float],
        sampleRate: Double,
        config: KeyDetectorConfig
    ) -> [Float] {
        let frameSize = config.frameSize
        let fft = RealFFT(n: frameSize)
        let window = Windows.hann(frameSize)
        let hpcp = HPCP(
            size: 12,
            harmonics: config.harmonics,
            referenceFrequency: config.referenceFrequency,
            minFrequency: config.minFrequency,
            maxFrequency: config.maxFrequency
        )

        var accumulated = [Float](repeating: 0, count: 12)
        var frameCount = 0

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset + frameSize <= samples.count {
                let spectrum = fft.magnitudeSpectrum(frame: base + offset, window: window)

                var peaks = SpectralPeaks.detect(
                    spectrum: spectrum,
                    sampleRate: sampleRate,
                    minFrequency: config.minFrequency,
                    maxFrequency: config.maxFrequency,
                    magnitudeThreshold: config.peakThreshold,
                    maxPeaks: config.maxPeaks
                )

                if config.useWhitening {
                    peaks = SpectralWhitening.whiten(
                        peaks: peaks,
                        spectrum: spectrum,
                        sampleRate: sampleRate,
                        maxFrequency: config.maxFrequency
                    )
                }

                if !peaks.isEmpty {
                    var frameProfile = [Float](repeating: 0, count: 12)
                    hpcp.accumulate(peaks: peaks, into: &frameProfile)
                    for i in 0..<12 { accumulated[i] += frameProfile[i] }
                    frameCount += 1
                }

                offset += config.hopSize
            }
        }

        guard frameCount > 0 else { return accumulated }
        for i in 0..<12 { accumulated[i] /= Float(frameCount) }

        // Normalise to peak 1, then gate away the noise floor.
        if let peak = accumulated.max(), peak > 0 {
            for i in 0..<12 {
                accumulated[i] /= peak
                if accumulated[i] < config.pcpThreshold { accumulated[i] = 0 }
            }
        }
        return accumulated
    }

    /// Correlate the chromagram against all 24 key profiles and take the strongest.
    static func classify(chroma: [Float], config: KeyDetectorConfig) -> KeyResult {
        let major = config.profile.major
        let minor = config.profile.minor

        let (chromaMean, chromaDeviation) = meanAndDeviation(chroma)
        let (majorMean, majorDeviation) = meanAndDeviation(major)
        let (minorMean, minorDeviation) = meanAndDeviation(minor)

        var bestMajor = -Float.greatestFiniteMagnitude
        var bestMajorIndex = 0
        var bestMinor = -Float.greatestFiniteMagnitude
        var bestMinorIndex = 0

        for shift in 0..<12 {
            let majorCorrelation = correlate(
                chroma, chromaMean, chromaDeviation, major, majorMean, majorDeviation, shift
            )
            if majorCorrelation > bestMajor {
                bestMajor = majorCorrelation
                bestMajorIndex = shift
            }

            let minorCorrelation = correlate(
                chroma, chromaMean, chromaDeviation, minor, minorMean, minorDeviation, shift
            )
            if minorCorrelation > bestMinor {
                bestMinor = minorCorrelation
                bestMinorIndex = shift
            }
        }

        // Ties resolve to minor, matching the reference implementation's ordering.
        if bestMajor > bestMinor {
            return KeyResult(
                tonic: pitchNames[bestMajorIndex],
                scale: "major",
                strength: Double(bestMajor)
            )
        }
        return KeyResult(
            tonic: pitchNames[bestMinorIndex],
            scale: "minor",
            strength: Double(bestMinor)
        )
    }

    private static func meanAndDeviation(_ values: [Float]) -> (Float, Float) {
        guard !values.isEmpty else { return (0, 0) }
        let mean = values.reduce(0, +) / Float(values.count)
        var sumSquares: Float = 0
        for value in values { sumSquares += (value - mean) * (value - mean) }
        return (mean, sumSquares.squareRoot())
    }

    private static func correlate(
        _ v1: [Float], _ mean1: Float, _ deviation1: Float,
        _ v2: [Float], _ mean2: Float, _ deviation2: Float,
        _ shift: Int
    ) -> Float {
        guard deviation1 != 0, deviation2 != 0 else { return 0 }
        let size = v1.count
        var sum: Float = 0
        for i in 0..<size {
            var index = (i - shift) % size
            if index < 0 { index += size }
            sum += (v1[i] - mean1) * (v2[index] - mean2)
        }
        return sum / (deviation1 * deviation2)
    }
}

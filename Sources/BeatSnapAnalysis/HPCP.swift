import Foundation

/// Harmonic Pitch Class Profile — a 12-bin chromagram built from spectral peaks, where each
/// peak also votes for the fundamentals it could be a harmonic of (Gómez, 2006).
///
/// Bin 0 is the reference pitch class (A, since the reference frequency is 440 Hz).
struct HPCP {
    struct HarmonicPeak {
        var semitone: Float
        var strength: Float
    }

    let size: Int
    let referenceFrequency: Float
    let minFrequency: Float
    let maxFrequency: Float
    let windowSize: Float
    private let harmonicPeaks: [HarmonicPeak]

    init(
        size: Int = 12,
        harmonics: Int = 4,
        referenceFrequency: Float = 440,
        minFrequency: Float = 25,
        maxFrequency: Float = 3500,
        windowSize: Float = 1.0
    ) {
        self.size = size
        self.referenceFrequency = referenceFrequency
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.windowSize = windowSize
        self.harmonicPeaks = Self.harmonicContributionTable(harmonics: harmonics)
    }

    /// Semitone offsets (folded into one octave) of harmonics 1...N, with weights that
    /// discount higher octaves. Duplicate offsets accumulate their strength.
    private static func harmonicContributionTable(harmonics: Int) -> [HarmonicPeak] {
        let precision: Float = 0.00001
        var table = [HarmonicPeak]()

        for i in 0...harmonics {
            var semitone = 12 * log2(Float(i) + 1)
            let octaveWeight = max(1, (semitone / 12) * 0.5)

            while semitone >= 12 - precision { semitone -= 12 }

            let strength = 1 / octaveWeight
            if let existing = table.firstIndex(where: {
                $0.semitone > semitone - precision && $0.semitone < semitone + precision
            }) {
                table[existing].strength += strength
            } else {
                table.append(HarmonicPeak(semitone: semitone, strength: strength))
            }
        }
        return table
    }

    /// Accumulate one frame's peaks into `profile` (length `size`).
    func accumulate(peaks: [SpectralPeak], into profile: inout [Float]) {
        for peak in peaks {
            guard peak.frequency >= minFrequency, peak.frequency <= maxFrequency else { continue }
            for harmonic in harmonicPeaks {
                let fundamental = peak.frequency * pow(2, -harmonic.semitone / 12)
                addContribution(
                    frequency: fundamental,
                    magnitude: peak.magnitude,
                    harmonicWeight: harmonic.strength,
                    into: &profile
                )
            }
        }
    }

    private func addContribution(
        frequency: Float,
        magnitude: Float,
        harmonicWeight: Float,
        into profile: inout [Float]
    ) {
        guard frequency > 0 else { return }
        let resolution = Float(size) / 12
        let binF = log2(frequency / referenceFrequency) * Float(size)

        let leftBin = Int(ceil(binF - resolution * windowSize / 2))
        let rightBin = Int(floor(binF + resolution * windowSize / 2))
        guard rightBin >= leftBin else { return }

        for bin in leftBin...rightBin {
            let distance = abs(binF - Float(bin)) / resolution
            let normalized = distance / windowSize
            let weight = cos(.pi * normalized)

            var wrapped = bin % size
            if wrapped < 0 { wrapped += size }
            profile[wrapped] += weight * (magnitude * magnitude) * (harmonicWeight * harmonicWeight)
        }
    }
}

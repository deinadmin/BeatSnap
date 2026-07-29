import Foundation

struct SpectralPeak {
    var frequency: Float
    var magnitude: Float
}

enum SpectralPeaks {
    /// Local maxima of a magnitude spectrum with quadratic interpolation, restricted to
    /// a frequency band, ordered by descending magnitude and capped at `maxPeaks`.
    static func detect(
        spectrum: [Float],
        sampleRate: Double,
        minFrequency: Float,
        maxFrequency: Float,
        magnitudeThreshold: Float,
        maxPeaks: Int
    ) -> [SpectralPeak] {
        let bins = spectrum.count
        guard bins > 3 else { return [] }

        // Bin index -> Hz. The last bin sits at Nyquist.
        let binToHz = Float(sampleRate / 2) / Float(bins - 1)

        var peaks = [SpectralPeak]()
        peaks.reserveCapacity(64)

        for i in 1..<(bins - 1) {
            let mid = spectrum[i]
            guard mid > magnitudeThreshold else { continue }
            let left = spectrum[i - 1]
            let right = spectrum[i + 1]
            guard mid > left, mid > right else { continue }

            // Quadratic (parabolic) interpolation of the true peak position/height.
            let denominator = left - 2 * mid + right
            var position = Float(i)
            var value = mid
            if denominator != 0 {
                let delta = 0.5 * (left - right) / denominator
                position = Float(i) + delta
                value = mid - 0.25 * (left - right) * delta
            }

            let frequency = position * binToHz
            guard frequency >= minFrequency, frequency <= maxFrequency else { continue }
            peaks.append(SpectralPeak(frequency: frequency, magnitude: value))
        }

        if peaks.count > maxPeaks {
            peaks.sort { $0.magnitude > $1.magnitude }
            peaks.removeLast(peaks.count - maxPeaks)
        }
        return peaks
    }
}

/// Flattens spectral peak magnitudes against a local noise envelope so that timbre and
/// bass weight stop dominating the pitch class profile.
///
/// Follows the envelope-and-difference formulation used by essentia's SpectralWhitening
/// (after Gómez's tonal description work): a weighted local energy average is sampled on a
/// 100 Hz grid, interpolated, and each peak is expressed as its dB distance from it.
enum SpectralWhitening {
    static let bpfResolution: Float = 100

    static func whiten(
        peaks: [SpectralPeak],
        spectrum: [Float],
        sampleRate: Double,
        maxFrequency: Float
    ) -> [SpectralPeak] {
        guard !peaks.isEmpty else { return peaks }

        let spectralRange = Float(sampleRate / 2)
        let specSize = spectrum.count

        // Peak magnitudes on an energy-dB scale.
        let magnitudesDB = peaks.map { 2 * linToDB($0.magnitude) }

        var maxAmp = -Float.greatestFiniteMagnitude
        for (i, peak) in peaks.enumerated() where peak.frequency <= maxFrequency {
            maxAmp = max(maxAmp, magnitudesDB[i])
        }

        // Sample a weighted local energy average on a fixed grid.
        var envelopeX = [Float]()
        var envelopeY = [Float]()
        var frequency: Float = 0
        while frequency <= maxFrequency && frequency <= spectralRange {
            let beginHz = frequency - max(50, frequency * 0.34)
            let endHz = frequency + max(50, frequency * 0.58)
            var begin = Int(beginHz / spectralRange * Float(specSize - 1) + 0.5)
            var end = Int(endHz / spectralRange * Float(specSize - 1) + 0.5)
            begin = min(max(begin, 0), specSize - 1)
            end = min(max(end, begin + 1), specSize)

            let center = Float(begin) / 2 + Float(end) / 2
            let halfWindow = Float(end) - center

            var weightedSum: Float = 0
            var weightTotal: Float = 0
            for i in begin..<end {
                var weight = 1 - abs(Float(i) - center) / halfWindow
                weight *= weight
                weight *= weight
                let energy = spectrum[i] * spectrum[i]
                weight *= energy
                weightedSum += energy * weight
                weightTotal += weight
            }
            if weightTotal != 0 { weightedSum /= weightTotal }

            envelopeX.append(frequency)
            envelopeY.append(weightedSum)
            frequency += bpfResolution
        }

        guard envelopeY.count >= 2 else { return peaks }
        envelopeY[envelopeY.count - 1] = envelopeY[envelopeY.count - 2]
        for i in envelopeY.indices {
            envelopeY[i] = 2 * linToDB(envelopeY[i].squareRoot())
        }

        var result = peaks
        for i in peaks.indices {
            let freq = peaks[i].frequency
            let amp = magnitudesDB[i]

            if freq > maxFrequency - bpfResolution {
                result[i].magnitude = dbToLin(amp / 2)
                continue
            }

            let envelope = interpolate(x: freq, xs: envelopeX, ys: envelopeY)
            var whitened: Float
            if amp > envelope {
                whitened = 0
            } else if amp > envelope - 30 {
                whitened = amp - envelope
            } else {
                whitened = -200
            }
            whitened -= 20 * freq / 4000
            result[i].magnitude = dbToLin(whitened / 2)
        }
        return result
    }

    private static func interpolate(x: Float, xs: [Float], ys: [Float]) -> Float {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        let step = bpfResolution
        let index = min(Int((x - first) / step), xs.count - 2)
        let t = (x - xs[index]) / (xs[index + 1] - xs[index])
        return ys[index] + t * (ys[index + 1] - ys[index])
    }

    private static func linToDB(_ x: Float) -> Float {
        10 * log10(max(x, 1e-30))
    }

    private static func dbToLin(_ x: Float) -> Float {
        pow(10, x / 10)
    }
}

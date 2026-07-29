import Accelerate
import Foundation

public struct TempoResult: Sendable {
    public let bpm: Double
    /// Relative confidence of the winning tempo against the runner-up, 0...1.
    public let confidence: Double

    public var roundedBPM: Int { Int(bpm.rounded()) }
}

public struct TempoConfig: Sendable {
    public var frameSize = 2048
    public var hopSize = 512
    public var melBands = 40
    public var melMinFrequency: Float = 30
    public var melMaxFrequency: Float = 11025

    /// Onset envelope is flattened against a moving average this many seconds wide.
    public var movingAverageSeconds = 1.0

    public var minBPM = 50.0
    public var maxBPM = 210.0
    /// Beat-period multiples summed by the comb filter; rewards periodicity that also
    /// holds at the bar level, which is what disambiguates tempo octaves.
    public var combMultiples = 6
    /// Weight of the k-th multiple, as 1/k^combDecay.
    public var combDecay = 0.5
    /// Log-normal prior over tempo, centred here.
    public var priorCenterBPM = 120.0
    /// Prior width in octaves. Larger = weaker pull toward the centre.
    public var priorSigmaOctaves = 1.1
    public var candidateStep = 0.02

    public init() {}
}

public enum TempoDetector {
    public static func detect(
        samples: [Float],
        sampleRate: Double,
        config: TempoConfig = TempoConfig()
    ) -> TempoResult {
        let envelope = onsetEnvelope(samples: samples, sampleRate: sampleRate, config: config)
        let frameRate = sampleRate / Double(config.hopSize)
        return estimateTempo(envelope: envelope, frameRate: frameRate, config: config)
    }

    // MARK: - Onset envelope

    /// Half-wave-rectified spectral flux across mel bands: the standard onset strength
    /// signal. dB compression keeps quiet hats as visible as loud kicks.
    public static func onsetEnvelope(
        samples: [Float],
        sampleRate: Double,
        config: TempoConfig
    ) -> [Float] {
        let frameSize = config.frameSize
        guard samples.count > frameSize else { return [] }

        let fft = RealFFT(n: frameSize)
        let window = Windows.hann(frameSize)
        let filterBank = melFilterBank(
            bands: config.melBands,
            fftSize: frameSize,
            sampleRate: sampleRate,
            minFrequency: config.melMinFrequency,
            maxFrequency: config.melMaxFrequency
        )

        var envelope = [Float]()
        envelope.reserveCapacity(samples.count / config.hopSize + 1)
        var previous = [Float](repeating: 0, count: config.melBands)
        var isFirst = true

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset + frameSize <= samples.count {
                let spectrum = fft.magnitudeSpectrum(frame: base + offset, window: window)

                var bands = [Float](repeating: 0, count: config.melBands)
                for b in 0..<config.melBands {
                    let filter = filterBank[b]
                    var sum: Float = 0
                    for (bin, weight) in filter {
                        let magnitude = spectrum[bin]
                        sum += weight * magnitude * magnitude
                    }
                    bands[b] = 10 * log10(max(sum, 1e-10))
                }

                if isFirst {
                    isFirst = false
                } else {
                    var flux: Float = 0
                    for b in 0..<config.melBands {
                        let difference = bands[b] - previous[b]
                        if difference > 0 { flux += difference }
                    }
                    envelope.append(flux)
                }
                previous = bands
                offset += config.hopSize
            }
        }

        return normalizeEnvelope(envelope, frameRate: sampleRate / Double(config.hopSize), config: config)
    }

    /// Remove slow loudness drift, rectify, and scale to unit deviation so that ACF peaks
    /// reflect rhythmic regularity rather than overall level.
    private static func normalizeEnvelope(
        _ envelope: [Float],
        frameRate: Double,
        config: TempoConfig
    ) -> [Float] {
        guard !envelope.isEmpty else { return envelope }

        let windowLength = max(3, Int(config.movingAverageSeconds * frameRate))
        var result = [Float](repeating: 0, count: envelope.count)

        // Centred moving average via a running sum.
        let half = windowLength / 2
        var runningSum: Float = 0
        var windowStart = 0
        var windowEnd = 0
        for i in envelope.indices {
            let desiredStart = max(0, i - half)
            let desiredEnd = min(envelope.count, i + half + 1)
            while windowEnd < desiredEnd {
                runningSum += envelope[windowEnd]
                windowEnd += 1
            }
            while windowStart < desiredStart {
                runningSum -= envelope[windowStart]
                windowStart += 1
            }
            let average = runningSum / Float(windowEnd - windowStart)
            result[i] = max(0, envelope[i] - average)
        }

        let mean = result.reduce(0, +) / Float(result.count)
        var variance: Float = 0
        for value in result { variance += (value - mean) * (value - mean) }
        let deviation = (variance / Float(result.count)).squareRoot()
        if deviation > 0 {
            for i in result.indices { result[i] /= deviation }
        }
        return result
    }

    // MARK: - Tempo from the onset envelope

    public static func estimateTempo(
        envelope: [Float],
        frameRate: Double,
        config: TempoConfig
    ) -> TempoResult {
        guard envelope.count > 16 else { return TempoResult(bpm: 0, confidence: 0) }

        let minLag = 60 * frameRate / config.maxBPM
        let maxLag = 60 * frameRate / config.minBPM
        let maxNeededLag = Int((maxLag * Double(config.combMultiples)).rounded(.up)) + 2
        let correlation = autocorrelation(envelope, maxLag: min(maxNeededLag, envelope.count - 1))

        var bestScore = -Double.greatestFiniteMagnitude
        var bestLag = minLag
        // Track the best score in each tempo octave so confidence reflects genuine
        // competition rather than neighbouring candidates for the same peak.
        var runnerUp = -Double.greatestFiniteMagnitude

        var lag = minLag
        while lag <= maxLag {
            let bpm = 60 * frameRate / lag
            var score = 0.0
            for k in 1...config.combMultiples {
                let weight = 1.0 / pow(Double(k), config.combDecay)
                score += weight * Double(interpolate(correlation, at: lag * Double(k)))
            }
            score *= prior(bpm: bpm, config: config)

            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
            lag += config.candidateStep
        }

        // Runner-up: the best score at least a semitone-ish away in tempo (>6%),
        // so half/double-time competitors count but the peak's own shoulders don't.
        lag = minLag
        while lag <= maxLag {
            let ratio = lag / bestLag
            if abs(log2(ratio)) > 0.08 {
                let bpm = 60 * frameRate / lag
                var score = 0.0
                for k in 1...config.combMultiples {
                    let weight = 1.0 / pow(Double(k), config.combDecay)
                    score += weight * Double(interpolate(correlation, at: lag * Double(k)))
                }
                score *= prior(bpm: bpm, config: config)
                if score > runnerUp { runnerUp = score }
            }
            lag += config.candidateStep
        }

        let bpm = 60 * frameRate / bestLag
        var confidence = 0.0
        if bestScore > 0, runnerUp > 0 {
            confidence = max(0, min(1, (bestScore - runnerUp) / bestScore))
        } else if bestScore > 0 {
            confidence = 1
        }
        return TempoResult(bpm: bpm, confidence: confidence)
    }

    private static func prior(bpm: Double, config: TempoConfig) -> Double {
        let octaves = log2(bpm / config.priorCenterBPM)
        let z = octaves / config.priorSigmaOctaves
        return exp(-0.5 * z * z)
    }

    private static func autocorrelation(_ signal: [Float], maxLag: Int) -> [Float] {
        var result = [Float](repeating: 0, count: maxLag + 1)
        let n = signal.count
        signal.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in 0...maxLag {
                let count = n - lag
                guard count > 0 else { break }
                var sum: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &sum, vDSP_Length(count))
                // Unbiased: longer lags average over fewer products.
                result[lag] = sum / Float(count)
            }
        }
        return result
    }

    private static func interpolate(_ values: [Float], at position: Double) -> Float {
        guard position >= 0 else { return 0 }
        let lower = Int(position)
        guard lower + 1 < values.count else { return values.isEmpty ? 0 : values[values.count - 1] }
        let t = Float(position - Double(lower))
        return values[lower] * (1 - t) + values[lower + 1] * t
    }

    // MARK: - Mel filter bank

    /// Triangular mel-spaced filters as (bin, weight) pairs per band.
    static func melFilterBank(
        bands: Int,
        fftSize: Int,
        sampleRate: Double,
        minFrequency: Float,
        maxFrequency: Float
    ) -> [[(Int, Float)]] {
        let binCount = fftSize / 2 + 1
        let nyquist = Float(sampleRate / 2)
        let topFrequency = min(maxFrequency, nyquist)

        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let minMel = hzToMel(minFrequency)
        let maxMel = hzToMel(topFrequency)
        let points = (0...(bands + 1)).map { i -> Float in
            melToHz(minMel + (maxMel - minMel) * Float(i) / Float(bands + 1))
        }

        let binToHz = nyquist / Float(binCount - 1)
        var bank = [[(Int, Float)]]()
        bank.reserveCapacity(bands)

        for b in 0..<bands {
            let left = points[b]
            let center = points[b + 1]
            let right = points[b + 2]
            var filter = [(Int, Float)]()
            let startBin = max(0, Int(left / binToHz))
            let endBin = min(binCount - 1, Int(right / binToHz) + 1)
            guard startBin <= endBin else {
                bank.append(filter)
                continue
            }
            for bin in startBin...endBin {
                let frequency = Float(bin) * binToHz
                var weight: Float = 0
                if frequency >= left && frequency <= center && center > left {
                    weight = (frequency - left) / (center - left)
                } else if frequency > center && frequency <= right && right > center {
                    weight = (right - frequency) / (right - center)
                }
                if weight > 0 { filter.append((bin, weight)) }
            }
            bank.append(filter)
        }
        return bank
    }
}

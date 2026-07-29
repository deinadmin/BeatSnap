import Accelerate

/// Reusable real-to-complex FFT producing a magnitude spectrum of `n/2 + 1` bins.
final class RealFFT {
    let n: Int
    private let halfN: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]
    private var windowed: [Float]

    init(n: Int) {
        precondition(n > 0 && (n & (n - 1)) == 0, "FFT size must be a power of two")
        self.n = n
        self.halfN = n / 2
        self.log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Could not create FFT setup for n=\(n)")
        }
        self.setup = setup
        self.realp = [Float](repeating: 0, count: halfN)
        self.imagp = [Float](repeating: 0, count: halfN)
        self.windowed = [Float](repeating: 0, count: n)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitude spectrum of `frame` (length `n`) multiplied elementwise by `window`.
    /// Returns amplitude magnitudes for bins 0...n/2 (DC through Nyquist).
    func magnitudeSpectrum(frame: UnsafePointer<Float>, window: [Float]) -> [Float] {
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var magnitudes = [Float](repeating: 0, count: halfN + 1)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                // Deinterleave the real signal into the packed split-complex layout
                // vDSP_fft_zrip expects.
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // Packed output: realp[0] = DC, imagp[0] = Nyquist, both real-valued.
                // vDSP scales the forward transform by 2, so undo that.
                magnitudes[0] = abs(realBuf[0]) * 0.5
                magnitudes[halfN] = abs(imagBuf[0]) * 0.5
                for k in 1..<halfN {
                    let re = realBuf[k]
                    let im = imagBuf[k]
                    magnitudes[k] = (re * re + im * im).squareRoot() * 0.5
                }
            }
        }

        return magnitudes
    }
}

enum Windows {
    /// Hann window, `0.5 - 0.5*cos(2*pi*i/(size-1))`.
    ///
    /// When `normalized` is true the window is scaled by `2/sum(w)` so that spectrum
    /// magnitudes are independent of frame size. This is not cosmetic: spectral whitening
    /// passes peaks near its frequency ceiling through with *raw* magnitudes while
    /// whitening everything else to ~1.0, so an unnormalized (frame-size-scaled) spectrum
    /// lets those few peaks dominate the whole chromagram.
    static func hann(_ size: Int, normalized: Bool = true) -> [Float] {
        guard size > 1 else { return [1] }
        let denominator = Float(size - 1)
        var window = (0..<size).map { i in
            0.5 - 0.5 * cos(2 * .pi * Float(i) / denominator)
        }
        if normalized {
            let sum = window.reduce(0, +)
            if sum > 0 {
                let scale = 2 / sum
                for i in window.indices { window[i] *= scale }
            }
        }
        return window
    }
}

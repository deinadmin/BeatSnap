import AVFoundation

/// Mono PCM decoded from any AVFoundation-readable file, resampled to a target rate.
public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public var durationSec: Double { Double(samples.count) / sampleRate }
}

public enum AudioDecoderError: Error, CustomStringConvertible {
    case unsupportedFormat
    case emptyAudio

    public var description: String {
        switch self {
        case .unsupportedFormat: "Could not read this audio file."
        case .emptyAudio: "The audio file contains no samples."
        }
    }
}

public enum AudioDecoder {
    /// Decode `url` to mono Float32 at `sampleRate`, reading at most `maxSeconds`.
    ///
    /// Replaces the old `ffmpeg -ac 1 -ar 44100 -f f32le` analysis path: AVFoundation
    /// handles WAV/M4A/AAC/MP3/AIFF natively and downmix+resample happen in one pass.
    public static func decodeMono(
        url: URL,
        sampleRate: Double = 44100,
        maxSeconds: Double = 180
    ) throws -> DecodedAudio {
        let inFile = try AVAudioFile(forReading: url)
        let inFormat = inFile.processingFormat

        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw AudioDecoderError.unsupportedFormat }

        // Proper (L+R)/2-style downmix rather than dropping to channel 0.
        converter.downmix = true

        let readChunk: AVAudioFrameCount = 1 << 14
        let outChunk: AVAudioFrameCount = 1 << 14
        let maxSamples = Int(maxSeconds * sampleRate)

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readChunk) else {
            throw AudioDecoderError.unsupportedFormat
        }

        var samples = [Float]()
        samples.reserveCapacity(min(maxSamples, Int(Double(inFile.length) * sampleRate / inFormat.sampleRate) + 1))

        var sourceExhausted = false
        while samples.count < maxSamples {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outChunk) else { break }

            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if sourceExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                // AVAudioFile throws eofErr (-39) on the final short read rather than
                // returning a 0-length buffer, so treat a throw as end-of-stream.
                do {
                    try inFile.read(into: inBuffer, frameCount: readChunk)
                } catch {
                    sourceExhausted = true
                }
                if inBuffer.frameLength == 0 {
                    sourceExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }

            if let conversionError { throw conversionError }

            let produced = Int(outBuffer.frameLength)
            if produced > 0, let channel = outBuffer.floatChannelData?[0] {
                let wanted = min(produced, maxSamples - samples.count)
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: wanted))
            }

            if status == .endOfStream || status == .error { break }
            if produced == 0 && sourceExhausted { break }
        }

        guard !samples.isEmpty else { throw AudioDecoderError.emptyAudio }
        return DecodedAudio(samples: samples, sampleRate: sampleRate)
    }

    /// Full duration of a file in seconds, read from its header rather than by decoding.
    ///
    /// `decodeMono` stops at `maxSeconds`, so its result can't be used for this.
    public static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}

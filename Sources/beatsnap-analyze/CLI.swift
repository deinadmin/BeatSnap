import BeatSnapAnalysis
import Foundation

/// Ground-truth entry from the original BeatSnap library index.
struct GroundTruthBeat: Decodable {
    let title: String
    let filePath: String
    let bpm: Int
    let key: String
}

@main
struct CLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            exit(1)
        }

        switch arguments[0] {
        case "--validate":
            guard arguments.count > 1 else {
                printUsage()
                exit(1)
            }
            validate(indexPath: arguments[1], options: Array(arguments.dropFirst(2)))
        case "--sweep":
            guard arguments.count > 1 else {
                printUsage()
                exit(1)
            }
            sweep(indexPath: arguments[1])
        case "--sweepkey":
            guard arguments.count > 1 else {
                printUsage()
                exit(1)
            }
            sweepKey(indexPath: arguments[1])
        case "--debug":
            guard arguments.count > 1 else {
                printUsage()
                exit(1)
            }
            DebugProbe.run(path: arguments[1])
        default:
            analyze(paths: arguments)
        }
    }

    static func printUsage() {
        print(
            """
            usage:
              beatsnap-analyze <audio-file>...              analyze files
              beatsnap-analyze --validate <beats.json>      score against known BPM/key
                                 [--profile <name>]         key profile to use
                                 [--no-whitening]
              beatsnap-analyze --sweep <beats.json>         search tempo/key parameters
            """
        )
    }

    // MARK: - Analyze

    static func analyze(paths: [String]) {
        let analyzer = BeatAnalyzer()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                let started = Date()
                let result = try analyzer.analyze(url: url)
                let elapsed = Date().timeIntervalSince(started)
                print(
                    String(
                        format: "%@  %d BPM  %@  (%.1fs audio, analyzed in %.2fs)",
                        url.lastPathComponent, result.bpm, result.key,
                        result.analyzedSeconds, elapsed
                    )
                )
            } catch {
                print("\(url.lastPathComponent)  ERROR: \(error)")
            }
        }
    }

    // MARK: - Validate

    static func loadGroundTruth(_ indexPath: String) -> [GroundTruthBeat] {
        guard let data = FileManager.default.contents(atPath: indexPath) else {
            print("Could not read \(indexPath)")
            exit(1)
        }
        do {
            return try JSONDecoder().decode([GroundTruthBeat].self, from: data)
        } catch {
            print("Could not parse \(indexPath): \(error)")
            exit(1)
        }
    }

    static func validate(indexPath: String, options: [String]) {
        var keyConfig = KeyDetectorConfig()
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--profile":
                if index + 1 < options.count, let profile = KeyProfile(rawValue: options[index + 1]) {
                    keyConfig.profile = profile
                    index += 1
                }
            case "--no-whitening":
                keyConfig.useWhitening = false
            default:
                break
            }
            index += 1
        }

        let beats = loadGroundTruth(indexPath)
        let analyzer = BeatAnalyzer(key: keyConfig)

        var bpmExact = 0
        var bpmWithinOne = 0
        var bpmOctave = 0
        var keyExact = 0
        var keyRelated = 0
        var analyzed = 0

        print("profile: \(keyConfig.profile.rawValue), whitening: \(keyConfig.useWhitening)")
        print(String(repeating: "-", count: 104))
        print(
            String(
                format: "%-42@  %-16@  %-16@  %-8@  %@",
                "title" as NSString, "bpm (exp/got)" as NSString,
                "key (exp/got)" as NSString, "conf" as NSString, "" as NSString
            )
        )
        print(String(repeating: "-", count: 104))

        for beat in beats {
            let url = URL(fileURLWithPath: beat.filePath)
            guard FileManager.default.fileExists(atPath: beat.filePath) else { continue }
            guard let result = try? analyzer.analyze(url: url) else {
                print("\(beat.title.prefix(42))  DECODE FAILED")
                continue
            }
            analyzed += 1

            let bpmDelta = abs(result.bpm - beat.bpm)
            let ratio = Double(result.bpm) / Double(beat.bpm)
            let isOctave = abs(ratio - 2) < 0.03 || abs(ratio - 0.5) < 0.03
            if bpmDelta == 0 { bpmExact += 1 }
            if bpmDelta <= 1 { bpmWithinOne += 1 }
            if isOctave { bpmOctave += 1 }

            let keyMatch = result.key == beat.key
            if keyMatch { keyExact += 1 }
            if keyMatch || isRelated(expected: beat.key, got: result.key) { keyRelated += 1 }

            let bpmFlag = bpmDelta == 0 ? "ok" : (isOctave ? "OCTAVE" : "MISS")
            let keyFlag = keyMatch ? "ok" : (isRelated(expected: beat.key, got: result.key) ? "related" : "MISS")

            print(
                String(
                    format: "%-42@  %3d/%-3d %-8@  %-8@/%-8@ %-8@  %.2f",
                    String(beat.title.prefix(42)) as NSString,
                    beat.bpm, result.bpm, bpmFlag as NSString,
                    beat.key as NSString, result.key as NSString, keyFlag as NSString,
                    result.tempoConfidence
                )
            )
        }

        print(String(repeating: "-", count: 104))
        guard analyzed > 0 else {
            print("no files analyzed")
            return
        }
        func percent(_ n: Int) -> String {
            String(format: "%d/%d (%.0f%%)", n, analyzed, 100 * Double(n) / Double(analyzed))
        }
        print("BPM exact:        \(percent(bpmExact))")
        print("BPM within 1:     \(percent(bpmWithinOne))")
        print("BPM octave error: \(percent(bpmOctave))")
        print("Key exact:        \(percent(keyExact))")
        print("Key exact+rel:    \(percent(keyRelated))")
    }

    /// Relative major/minor, or a perfect-fifth neighbour — the classic near-misses that a
    /// producer would still recognise as compatible.
    static func isRelated(expected: String, got: String) -> Bool {
        let names = ["A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"]
        func parse(_ value: String) -> (Int, Bool)? {
            let parts = value.split(separator: " ")
            guard parts.count == 2, let index = names.firstIndex(of: String(parts[0])) else { return nil }
            return (index, parts[1] == "minor")
        }
        guard let (expectedIndex, expectedMinor) = parse(expected),
              let (gotIndex, gotMinor) = parse(got) else { return false }

        let distance = ((gotIndex - expectedIndex) % 12 + 12) % 12
        // Relative major/minor: minor tonic is 3 semitones below its relative major.
        if expectedMinor != gotMinor {
            if expectedMinor && distance == 3 { return true }
            if !expectedMinor && distance == 9 { return true }
        }
        // Same mode, a fifth apart.
        if expectedMinor == gotMinor && (distance == 7 || distance == 5) { return true }
        return false
    }

    // MARK: - Key parameter sweep

    /// Vary the analysis parameters of the key pipeline (profile fixed to the best
    /// performer) to see whether framing/peak choices explain the remaining mismatches.
    static func sweepKey(indexPath: String) {
        let beats = loadGroundTruth(indexPath).filter {
            FileManager.default.fileExists(atPath: $0.filePath)
        }
        var decoded = [(beat: GroundTruthBeat, audio: DecodedAudio)]()
        for beat in beats {
            if let audio = try? AudioDecoder.decodeMono(
                url: URL(fileURLWithPath: beat.filePath), sampleRate: 44100, maxSeconds: 180
            ) {
                decoded.append((beat, audio))
            }
        }
        print("decoded \(decoded.count)\n")
        print(
            String(
                format: "%-6@ %-6@ %-7@ %-6@ %-6@ %-7@ %@",
                "hop" as NSString, "frame" as NSString, "maxHz" as NSString,
                "peaks" as NSString, "harm" as NSString, "gate" as NSString, "exact" as NSString
            )
        )

        var best = (score: -1, description: "")
        for hop in [4096, 2048] {
            for frame in [4096, 8192] {
                for maxHz in [Float(3500), 5000] {
                    for peaks in [60, 100] {
                        for harmonics in [4, 8] {
                            for gate in [Float(0.2), 0.0] {
                                var config = KeyDetectorConfig()
                                config.hopSize = hop
                                config.frameSize = frame
                                config.maxFrequency = maxHz
                                config.maxPeaks = peaks
                                config.harmonics = harmonics
                                config.pcpThreshold = gate

                                var exact = 0
                                for (beat, audio) in decoded {
                                    let result = KeyDetector.detect(
                                        samples: audio.samples,
                                        sampleRate: audio.sampleRate,
                                        config: config
                                    )
                                    if result.name == beat.key { exact += 1 }
                                }
                                if exact > best.score {
                                    best = (
                                        exact,
                                        "hop=\(hop) frame=\(frame) maxHz=\(maxHz) peaks=\(peaks) harmonics=\(harmonics) gate=\(gate)"
                                    )
                                    print(
                                        String(
                                            format: "%-6d %-6d %-7.0f %-6d %-6d %-7.1f %@  <- best",
                                            hop, frame, maxHz, peaks, harmonics, gate,
                                            "\(exact)/\(decoded.count)" as NSString
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        print("\nbest key config: \(best.description) → \(best.score)/\(decoded.count)")
    }

    // MARK: - Sweep

    static func sweep(indexPath: String) {
        let beats = loadGroundTruth(indexPath).filter {
            FileManager.default.fileExists(atPath: $0.filePath)
        }
        guard !beats.isEmpty else {
            print("no ground-truth files found on disk")
            return
        }

        // Decode once, reuse for every parameter combination.
        print("decoding \(beats.count) files…")
        var decoded = [(beat: GroundTruthBeat, audio: DecodedAudio)]()
        for beat in beats {
            if let audio = try? AudioDecoder.decodeMono(
                url: URL(fileURLWithPath: beat.filePath), sampleRate: 44100, maxSeconds: 180
            ) {
                decoded.append((beat, audio))
            }
        }
        print("decoded \(decoded.count)\n")

        // --- Key: which profile and whitening setting agrees most often? ---
        print("KEY PROFILE SWEEP")
        print(String(format: "%-12@ %-10@ %-8@ %@", "profile" as NSString, "whitening" as NSString, "exact" as NSString, "exact+related" as NSString))
        for profile in KeyProfile.allCases {
            for whitening in [true, false] {
                var config = KeyDetectorConfig()
                config.profile = profile
                config.useWhitening = whitening
                var exact = 0
                var related = 0
                for (beat, audio) in decoded {
                    let result = KeyDetector.detect(
                        samples: audio.samples, sampleRate: audio.sampleRate, config: config
                    )
                    if result.name == beat.key {
                        exact += 1
                        related += 1
                    } else if isRelated(expected: beat.key, got: result.name) {
                        related += 1
                    }
                }
                print(
                    String(
                        format: "%-12@ %-10@ %-8@ %@",
                        profile.rawValue as NSString,
                        (whitening ? "on" : "off") as NSString,
                        "\(exact)/\(decoded.count)" as NSString,
                        "\(related)/\(decoded.count)" as NSString
                    )
                )
            }
        }

        // --- Tempo: prior width and comb depth drive octave errors. ---
        print("\nTEMPO SWEEP")
        print(String(format: "%-8@ %-8@ %-8@ %-10@ %@", "sigma" as NSString, "center" as NSString, "combs" as NSString, "decay" as NSString, "exact" as NSString))
        var envelopes = [(beat: GroundTruthBeat, envelope: [Float], frameRate: Double)]()
        let baseTempo = TempoConfig()
        for (beat, audio) in decoded {
            let envelope = TempoDetector.onsetEnvelope(
                samples: audio.samples, sampleRate: audio.sampleRate, config: baseTempo
            )
            envelopes.append((beat, envelope, audio.sampleRate / Double(baseTempo.hopSize)))
        }

        var best = (score: -1, description: "")
        for sigma in [0.5, 0.7, 0.9, 1.1, 1.4, 2.0] {
            for center in [100.0, 110.0, 120.0, 130.0] {
                for combs in [1, 2, 3, 4, 6] {
                    for decay in [0.5, 1.0, 1.5] {
                        var config = TempoConfig()
                        config.priorSigmaOctaves = sigma
                        config.priorCenterBPM = center
                        config.combMultiples = combs
                        config.combDecay = decay

                        var exact = 0
                        for (beat, envelope, frameRate) in envelopes {
                            let result = TempoDetector.estimateTempo(
                                envelope: envelope, frameRate: frameRate, config: config
                            )
                            if result.roundedBPM == beat.bpm { exact += 1 }
                        }
                        if exact > best.score {
                            best = (exact, "sigma=\(sigma) center=\(center) combs=\(combs) decay=\(decay)")
                            print(
                                String(
                                    format: "%-8.1f %-8.0f %-8d %-10.1f %@  <- best",
                                    sigma, center, combs, decay,
                                    "\(exact)/\(envelopes.count)" as NSString
                                )
                            )
                        }
                    }
                }
            }
        }
        print("\nbest tempo config: \(best.description) → \(best.score)/\(envelopes.count)")
    }
}

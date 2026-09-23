import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The directory is authoritative. Cached entries only avoid reopening unchanged audio.
enum BeatFolderScanner {
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\s*\[(\d+)BPM ([A-G][#b]?)(min|maj)\](?:\s*\(\d+\))?$"#
    )
    struct Entry {
        var beat: Beat
        let size: Int?
        let modified: Date?
        let created: Date?
    }

    static func scan(directory: URL, cached: [String: Entry], known: [Beat]) throws -> [String: Entry] {
        let manager = FileManager.default
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .fileSizeKey,
                                        .contentModificationDateKey, .creationDateKey,
                                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [])
        let knownByPath = Dictionary(known.map { ($0.filePath, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [String: Entry] = [:]
        for enumeratedURL in urls {
            try Task.checkCancellation()
            let logicalURL = CloudFileAccess.logicalURL(for: enumeratedURL)
            let isPlaceholder = logicalURL != enumeratedURL
            guard isPlaceholder || !enumeratedURL.lastPathComponent.hasPrefix(".") else { continue }
            // Resolve the existing parent, not a potentially absent cloud file. Foundation
            // can normalize /private/var differently depending on whether the child exists.
            let url = canonicalDirectory.appendingPathComponent(logicalURL.lastPathComponent)
            guard let labels = labels(in: url.deletingPathExtension().lastPathComponent),
                  let values = try? enumeratedURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.contentType?.conforms(to: .audio) == true
                    || UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true)
            else { continue }
            let needsDownload = isPlaceholder || CloudFileAccess.needsDownload(at: url, values: values)
            // During hydration both representations may briefly exist. Prefer the local file.
            if entries[url.path]?.beat.needsDownload == false { continue }

            if var entry = cached[url.path], entry.size == values.fileSize,
               entry.modified == values.contentModificationDate, entry.created == values.creationDate,
               entry.beat.needsDownload == needsDownload {
                // Preserve in-session import metadata and IDs across unchanged scans.
                if let beat = knownByPath[url.path] { entry.beat = beat }
                entry.beat.needsDownload = needsDownload
                entries[url.path] = entry
                continue
            }
            let previous = knownByPath[url.path]
            var duration = previous?.durationSec ?? 0
            if !needsDownload {
                guard manager.isReadableFile(atPath: url.path),
                      let audio = try? AVAudioFile(forReading: url), audio.length > 0,
                      audio.processingFormat.sampleRate > 0 else { continue }
                duration = Int((Double(audio.length) / audio.processingFormat.sampleRate).rounded())
            }
            let beat = Beat(
                id: previous?.id ?? Beat.makeID(), title: labels.title,
                fileName: url.lastPathComponent, filePath: url.path,
                bpm: labels.bpm, key: labels.key,
                durationSec: duration,
                createdAt: (values.creationDate ?? values.contentModificationDate ?? .distantPast)
                    .timeIntervalSince1970 * 1000,
                youtubeId: previous?.youtubeId, needsDownload: needsDownload
            )
            entries[url.path] = Entry(beat: beat, size: values.fileSize,
                                     modified: values.contentModificationDate, created: values.creationDate)
        }
        return entries
    }

    static func labels(in name: String) -> (title: String, bpm: Int, key: String)? {
        guard let match = tagPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let bpmRange = Range(match.range(at: 1), in: name),
              let tonicRange = Range(match.range(at: 2), in: name),
              let modeRange = Range(match.range(at: 3), in: name),
              let bpm = Int(name[bpmRange]), (1...999).contains(bpm)
        else { return nil }
        return (BeatStore.stripAnalysisTag(from: name), bpm,
                "\(name[tonicRange]) \(name[modeRange] == "min" ? "minor" : "major")")
    }
}

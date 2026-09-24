import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Public file downloads go straight to disk and retain their original encoding.
enum RemoteAudioDownloader {
    typealias Transfer = @Sendable (URL) async throws -> (URL, URLResponse)

    /// The caller owns `directory` and removes it after import, including on failure.
    static func download(_ link: DownloadLink, into directory: URL,
                         transfer: Transfer? = nil) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fetch: Transfer = transfer ?? { try await session.download(from: $0) }
        var requestURL = link.downloadURL

        // A public Drive file can require one extra request through its download form.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let (temporaryURL, response) = try await fetch(requestURL)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DownloadError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                throw DownloadError.httpStatus(http.statusCode)
            }

            let handle = try FileHandle(forReadingFrom: temporaryURL)
            let prefix = try handle.read(upToCount: 256 * 1024) ?? Data()
            try handle.close()
            let text = String(decoding: prefix, as: UTF8.self)
            let startsAsHTML = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("<")
            if response.mimeType?.lowercased().contains("html") == true || startsAsHTML {
                if attempt == 0, let confirmation = driveConfirmation(in: text, for: link) {
                    requestURL = confirmation
                    continue
                }
                throw DownloadError.webPage(isShare: link.kind != .direct)
            }

            // Check real media before anything reaches the beats folder. Headers and file
            // extensions alone cannot distinguish an audio file from an error response.
            guard let audio = try? AVAudioFile(forReading: temporaryURL), audio.length > 0,
                  audio.processingFormat.sampleRate > 0 else { throw DownloadError.notAudio }
            let name = filename(for: response, link: link)
            let namedExtension = (name as NSString).pathExtension.lowercased()
            let ext: String
            if UTType(filenameExtension: namedExtension)?.conforms(to: .audio) == true {
                ext = namedExtension
            } else if let detected = audioExtension(at: temporaryURL) {
                ext = detected
            } else {
                throw DownloadError.notAudio
            }
            let title = BeatStore.sanitize(filename: (name as NSString).deletingPathExtension)
            let destination = directory.appendingPathComponent("\(title).\(ext)")
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        }
        throw DownloadError.webPage(isShare: true)
    }

    static func filename(for response: URLResponse, link: DownloadLink) -> String {
        // Foundation handles Content-Disposition (including encoded filenames) and redirects.
        let suggested = response.suggestedFilename
        if let suggested, suggested != "Unknown",
           (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") != nil {
            return suggested.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? suggested
        }
        for url in [response.url, link.originalURL].compactMap({ $0 }) {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true {
                return url.lastPathComponent
            }
        }
        return link.title
    }

    /// Extensionless and binary responses still work when Core Audio recognizes the container.
    private static func audioExtension(at url: URL) -> String? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout.size(ofValue: type))
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &type) == noErr else { return nil }
        return [kAudioFileWAVEType: "wav", kAudioFileAIFFType: "aiff", kAudioFileAIFCType: "aifc",
                kAudioFileM4AType: "m4a", kAudioFileMPEG4Type: "m4a", kAudioFileMP3Type: "mp3",
                kAudioFileAAC_ADTSType: "aac", kAudioFileCAFType: "caf", kAudioFileFLACType: "flac"][type]
    }

    /// Only submit Drive's own download form for the requested file. Never follow arbitrary
    /// page forms, sign-in prompts, or confirmation loops.
    static func driveConfirmation(in html: String, for link: DownloadLink) -> URL? {
        guard case .googleDrive(let id) = link.kind,
              let form = matches(#"(?is)<form\b[^>]*>.*?</form>"#, in: html)
                .first(where: { attributes(in: String($0.prefix(while: { $0 != ">" })))["id"] == "download-form" }),
              let action = attributes(in: String(form.prefix(while: { $0 != ">" })))["action"],
              var parts = URLComponents(string: action), parts.scheme == "https",
              ["drive.google.com", "drive.usercontent.google.com", "docs.google.com"].contains(parts.host),
              ["/uc", "/download"].contains(parts.path), parts.user == nil, parts.password == nil else { return nil }
        var fields = parts.queryItems ?? []
        for input in matches(#"(?is)<input\b[^>]*>"#, in: form) {
            let values = attributes(in: input)
            guard values["type"]?.lowercased() == "hidden", let name = values["name"],
                  let value = values["value"] else { continue }
            fields.removeAll { $0.name == name }
            fields.append(URLQueryItem(name: name, value: value))
        }
        guard fields.first(where: { $0.name == "id" })?.value == id,
              fields.first(where: { $0.name == "confirm" })?.value?.isEmpty == false else { return nil }
        if !fields.contains(where: { $0.name == "resourcekey" }),
           let key = URLComponents(url: link.downloadURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "resourcekey" }) { fields.append(key) }
        parts.queryItems = fields
        return parts.url
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([\w-]+)\s*=\s*[\"']([^\"']*)[\"']"#)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag),
                  let value = Range(match.range(at: 2), in: tag) else { continue }
            result[String(tag[key]).lowercased()] = String(tag[value])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
        }
        return result
    }

    enum DownloadError: LocalizedError {
        case invalidResponse, httpStatus(Int), webPage(isShare: Bool), notAudio
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The server did not return a valid download."
            case .httpStatus(let status):
                switch status {
                case 401, 403: "This file requires permission. Enable public link access and allow downloads."
                case 404: "The file could not be found. The link may have expired or the file was removed."
                case 429: "This file has reached its download limit. Try again later."
                default: "The server could not download the file (HTTP \(status))."
                }
            case .webPage(let isShare):
                isShare
                    ? "The share link returned a web page. Enable ‘Anyone with the link’ and downloads, or download in your browser and drop the audio file here."
                    : "This link opens a web page. Use a direct audio download link."
            case .notAudio: "The downloaded file is empty or is not a supported audio file."
            }
        }
    }
}

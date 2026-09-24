import Foundation
import UniformTypeIdentifiers

/// Classifies pasted links without making a request. Signed direct URLs are kept intact.
struct DownloadLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case youtube, direct, dropbox
        case googleDrive(id: String)
    }

    let originalURL: URL
    let downloadURL: URL
    let kind: Kind

    init(_ text: String) throws {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, let original = parts.url else {
            throw LinkError.invalidURL
        }
        originalURL = original
        if ["youtu.be", "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"].contains(host) {
            kind = .youtube
        } else if ["dropbox.com", "www.dropbox.com"].contains(host) {
            guard parts.path.hasPrefix("/s/") || parts.path.hasPrefix("/scl/fi/") else {
                throw LinkError.fileRequired
            }
            kind = .dropbox
            parts.queryItems = (parts.queryItems ?? []).filter { !["dl", "raw"].contains($0.name) }
                + [URLQueryItem(name: "dl", value: "1")]
            parts.fragment = nil
        } else if ["drive.google.com", "docs.google.com"].contains(host) {
            let path = parts.path.split(separator: "/").map(String.init)
            let id: String?
            if path.count >= 3, path[0] == "file", path[1] == "d" {
                id = path[2]
            } else if ["/open", "/uc", "/download"].contains(parts.path) {
                id = parts.queryItems?.first(where: { $0.name == "id" })?.value
            } else {
                id = nil
            }
            guard let id, !id.isEmpty,
                  id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw LinkError.fileRequired
            }
            kind = .googleDrive(id: id)
            let resourceKey = parts.queryItems?.first(where: { $0.name == "resourcekey" })
            parts = URLComponents(string: "https://drive.google.com/uc")!
            parts.queryItems = [URLQueryItem(name: "export", value: "download"),
                                URLQueryItem(name: "id", value: id)]
                + (resourceKey.map { [$0] } ?? [])
        } else {
            kind = .direct
        }
        guard let url = parts.url else { throw LinkError.invalidURL }
        downloadURL = url
    }

    var title: String {
        if case .googleDrive = kind { return "Google Drive audio" }
        let name = originalURL.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Audio from \(originalURL.host ?? "link")" : name
    }

    /// Clipboard suggestions stay conservative; a manually pasted extensionless URL is valid.
    var canSuggestFromClipboard: Bool {
        kind != .direct || UTType(filenameExtension: originalURL.pathExtension)?.conforms(to: .audio) == true
    }

    enum LinkError: LocalizedError {
        case invalidURL, fileRequired
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Paste a valid HTTP or HTTPS link."
            case .fileRequired: "Use a share link to a single audio file, rather than a folder or document."
            }
        }
    }
}

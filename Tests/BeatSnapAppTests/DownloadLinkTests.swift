import Foundation
import Testing
@testable import BeatSnapApp

struct DownloadLinkTests {
    @Test func signedDirectLinksRemainIntact() throws {
        let text = "https://files.example.com/beat.wav?token=a%2Bb%2Fc&expires=123"
        let link = try DownloadLink("  \(text)\n")
        #expect(link.kind == .direct)
        #expect(link.downloadURL.absoluteString == text)
        #expect(link.canSuggestFromClipboard)
        #expect(try !DownloadLink("https://example.com/download?token=123").canSuggestFromClipboard)
    }

    @Test func dropboxKeepsAccessKeysAndReplacesDownloadFlags() throws {
        let link = try DownloadLink("https://www.dropbox.com/scl/fi/abc/Beat.wav?rlkey=secret&dl=0&raw=1")
        let query = try #require(URLComponents(url: link.downloadURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(link.kind == .dropbox)
        #expect(query == [URLQueryItem(name: "rlkey", value: "secret"), URLQueryItem(name: "dl", value: "1")])
        #expect(try DownloadLink("https://dropbox.com/s/abc/Beat.mp3").kind == .dropbox)
    }

    @Test(arguments: ["https://drive.google.com/file/d/abc_123-XYZ/view?usp=sharing&resourcekey=key",
                      "https://drive.google.com/open?id=abc_123-XYZ&resourcekey=key",
                      "https://drive.google.com/uc?id=abc_123-XYZ&export=download&resourcekey=key"])
    func driveFileLinks(_ text: String) throws {
        let link = try DownloadLink(text)
        #expect(link.kind == .googleDrive(id: "abc_123-XYZ"))
        #expect(link.downloadURL.absoluteString == "https://drive.google.com/uc?export=download&id=abc_123-XYZ&resourcekey=key")
    }

    @Test(arguments: ["file:///tmp/beat.wav", "ftp://example.com/beat.wav", "hello", "https://",
                      "https://user:pass@example.com/beat.wav", "https://drive.google.com/drive/folders/abc",
                      "https://docs.google.com/document/d/abc/edit", "https://dropbox.com/scl/fo/abc"])
    func rejectsInvalidURLsAndFolders(_ text: String) {
        #expect(throws: DownloadLink.LinkError.self) { try DownloadLink(text) }
    }

    @Test func youtubeRoutingUsesExactHosts() throws {
        #expect(try DownloadLink("https://youtu.be/abc").kind == .youtube)
        #expect(try DownloadLink("https://www.youtube.com/watch?v=abc").kind == .youtube)
        #expect(try DownloadLink("https://youtube.com.example.com/beat.wav").kind == .direct)
        #expect(try DownloadLink("https://drive.google.com.example.com/beat.wav").kind == .direct)
    }
}

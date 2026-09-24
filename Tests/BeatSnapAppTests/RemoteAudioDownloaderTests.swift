import AVFoundation
import Foundation
import Testing
@testable import BeatSnapApp

struct RemoteAudioDownloaderTests {
    @Test func retainsAudioAndUsesResponseFilename() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try audioData(in: directory)
        let fixture = DownloadFixture(directory: directory, replies: [
            .init(data: bytes, headers: ["Content-Type": "application/octet-stream",
                                       "Content-Disposition": "attachment; filename=\"Shared Beat.wav\""])
        ])
        let link = try DownloadLink("https://drive.google.com/file/d/abc/view")
        let result = try await RemoteAudioDownloader.download(link, into: directory, transfer: { try await fixture.fetch($0) })
        #expect(result.lastPathComponent == "Shared Beat.wav")
        #expect(try Data(contentsOf: result) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Shared Beat.wav"])
    }

    @Test func extensionlessBinaryAudioIsRecognized() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = DownloadFixture(directory: directory, replies: [
            .init(data: try audioData(in: directory), headers: ["Content-Type": "application/octet-stream"])
        ])
        let result = try await RemoteAudioDownloader.download(
            DownloadLink("https://example.com/download?token=abc"), into: directory, transfer: { try await fixture.fetch($0) })
        #expect(result.lastPathComponent == "download.wav")
        #expect(try AVAudioFile(forReading: result).length > 0)
    }

    @Test(arguments: [200, 403, 404, 429, 500])
    func errorPagesNeverBecomeBeats(_ status: Int) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = DownloadFixture(directory: directory, replies: [
            .init(data: Data("<!doctype html><html>Please sign in</html>".utf8),
                  status: status, headers: ["Content-Type": "audio/wav"])
        ])
        await #expect(throws: RemoteAudioDownloader.DownloadError.self) {
            try await RemoteAudioDownloader.download(DownloadLink("https://example.com/beat.wav"),
                                                     into: directory, transfer: { try await fixture.fetch($0) })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func rejectsNonAudioAndRemovesTemporaryFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = DownloadFixture(directory: directory, replies: [
            .init(data: Data("not audio".utf8), headers: ["Content-Type": "audio/wav"])
        ])
        await #expect(throws: RemoteAudioDownloader.DownloadError.self) {
            try await RemoteAudioDownloader.download(DownloadLink("https://example.com/beat.wav"),
                                                     into: directory, transfer: { try await fixture.fetch($0) })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func followsDriveConfirmationOnceWithResourceKey() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = DownloadFixture(directory: directory, replies: [
            .init(data: Data(confirmation.utf8), headers: ["Content-Type": "text/html"]),
            .init(data: try audioData(in: directory), headers: ["Content-Disposition": "attachment; filename=Beat.wav"])
        ])
        let link = try DownloadLink("https://drive.google.com/file/d/abc/view?resourcekey=key")
        _ = try await RemoteAudioDownloader.download(link, into: directory, transfer: { try await fixture.fetch($0) })
        let requests = await fixture.requests
        #expect(requests.count == 2)
        #expect(requests.last?.host == "drive.usercontent.google.com")
        let query = URLComponents(url: try #require(requests.last), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "uuid", value: "one&two")) == true)
        #expect(query?.contains(URLQueryItem(name: "resourcekey", value: "key")) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Beat.wav"])
    }

    @Test func confirmationLoopsAndOtherFormsAreRejected() async throws {
        let link = try DownloadLink("https://drive.google.com/file/d/abc/view")
        for html in [confirmation.replacingOccurrences(of: "drive.usercontent.google.com", with: "example.com"),
                     confirmation.replacingOccurrences(of: "value=\"abc\"", with: "value=\"other\""),
                     confirmation.replacingOccurrences(of: "download-form", with: "login-form")] {
            #expect(RemoteAudioDownloader.driveConfirmation(in: html, for: link) == nil)
        }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = DownloadFixture.Reply(data: Data(confirmation.utf8), headers: ["Content-Type": "text/html"])
        let fixture = DownloadFixture(directory: directory, replies: [page, page])
        await #expect(throws: RemoteAudioDownloader.DownloadError.self) {
            try await RemoteAudioDownloader.download(link, into: directory, transfer: { try await fixture.fetch($0) })
        }
        #expect(await fixture.requests.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private var confirmation: String {
        """
        <html><form id="download-form" action="https://drive.usercontent.google.com/download" method="get">
        <input type="hidden" name="id" value="abc"><input value="t" name="confirm" type="hidden">
        <input type="hidden" name="uuid" value="one&amp;two"></form></html>
        """
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audioData(in directory: URL) throws -> Data {
        let url = directory.appendingPathComponent("fixture.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        buffer.floatChannelData![0].update(repeating: 0, count: 8000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }
}

private actor DownloadFixture {
    struct Reply: Sendable {
        let data: Data
        var status = 200
        var headers: [String: String] = [:]
    }
    let directory: URL
    var replies: [Reply]
    var requests: [URL] = []

    init(directory: URL, replies: [Reply]) {
        self.directory = directory
        self.replies = replies
    }

    func fetch(_ url: URL) throws -> (URL, URLResponse) {
        requests.append(url)
        let reply = replies.removeFirst()
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".download")
        try reply.data.write(to: temporary)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (temporary, response)
    }
}

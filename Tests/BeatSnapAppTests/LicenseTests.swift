import AppKit

import Foundation
import Security
import Testing
@testable import BeatSnapApp

struct LicenseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func signedReceiptAndOfflineLease() throws {
        let fixture = try fixture()
        let response = try fixture.response(payload())
        let certificate = try fixture.client.verify(response, key: "TEST-KEY", machine: "mac", now: now)
        #expect(certificate.expiration == now.addingTimeInterval(30 * 86400))
        #expect(certificate.usableUntil == now.addingTimeInterval(7 * 86400))
        #expect(throws: LicenseError.self) {
            try fixture.client.verify(response, key: "TEST-KEY", machine: "mac",
                                      now: now.addingTimeInterval(7 * 86400))
        }
    }

    @Test func expirationCapsOfflineLease() throws {
        let fixture = try fixture()
        var data = payload()
        data["Expires"] = now.addingTimeInterval(60).timeIntervalSince1970
        let response = try fixture.response(data)
        let certificate = try fixture.client.verify(response, key: "TEST-KEY", machine: "mac", now: now)
        #expect(certificate.usableUntil == now.addingTimeInterval(60))
        #expect(throws: LicenseError.self) {
            try fixture.client.verify(response, key: "TEST-KEY", machine: "mac", now: now.addingTimeInterval(60))
        }
    }

    @Test(arguments: ["ProductId", "Key", "Block", "ActivatedMachines", "Expires", "SignDate"])
    func rejectsSignedButInvalidLicense(_ field: String) throws {
        let fixture = try fixture()
        var data = payload()
        switch field {
        case "ProductId": data[field] = 99
        case "Key": data[field] = "OTHER"
        case "Block": data[field] = true
        case "ActivatedMachines": data[field] = [["Mid": "other-mac"]]
        case "Expires": data[field] = now.timeIntervalSince1970 - 1
        default: data[field] = now.timeIntervalSince1970 + 301
        }
        #expect(throws: LicenseError.self) {
            try fixture.client.verify(fixture.response(data), key: "TEST-KEY", machine: "mac", now: now)
        }
    }

    @Test func unlimitedMachineLicense() throws {
        let fixture = try fixture()
        var data = payload()
        data["MaxNoOfMachines"] = 0
        data["ActivatedMachines"] = []
        _ = try fixture.client.verify(fixture.response(data), key: "TEST-KEY", machine: "other", now: now)
    }

    @Test func rejectsTamperingWrongSigningKeyAndMissingSignature() throws {
        let fixture = try fixture()
        let response = try fixture.response(payload())
        let wrongSigner = try self.fixture()
        #expect(throws: LicenseError.self) {
            try wrongSigner.client.verify(response, key: "TEST-KEY", machine: "mac", now: now)
        }
        var envelope = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        var changed = payload()
        changed["Expires"] = now.timeIntervalSince1970 + 99999999
        envelope["licenseKey"] = try JSONSerialization.data(withJSONObject: changed).base64EncodedString()
        let altered = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: LicenseError.self) {
            try fixture.client.verify(altered, key: "TEST-KEY", machine: "mac", now: now)
        }
        envelope.removeValue(forKey: "signature")
        let unsigned = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: LicenseError.self) {
            try fixture.client.verify(unsigned, key: "TEST-KEY", machine: "mac", now: now)
        }
    }

    @Test func activationAndDeactivationRequestsEncodeCredentials() async throws {
        let config = LicenseConfiguration(productID: 42, accessToken: "a+b&c=", rsaPublicKey: "")
        for method in ["Activate", "Deactivate"] {
            let client = CryptolensClient(configuration: config, transfer: { request in
                #expect(request.url?.absoluteString == "https://api.cryptolens.io/api/key/\(method)")
                #expect(request.httpMethod == "POST")
                let body = String(data: try #require(request.httpBody), encoding: .utf8)
                #expect(body?.contains("token=a%2Bb%26c%3D") == true)
                #expect(body?.contains("MachineCode=mac") == true)
                #expect(body?.contains("SignMethod=1") == true)
                return (Data(#"{"result":0}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            _ = try await client.request(method, key: "TEST", machine: "mac")
        }
    }

    @Test func distinguishesRejectionFromOffline() async throws {
        let config = LicenseConfiguration(productID: 42, accessToken: "test", rsaPublicKey: "")
        let blocked = CryptolensClient(configuration: config, transfer: { request in
            (Data(#"{"result":1,"message":"Key is blocked"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await blocked.request("Activate", key: "TEST", machine: "mac")
            Issue.record("Expected rejection")
        } catch LicenseError.message(let message) { #expect(message == "Key is blocked") }
        let offline = CryptolensClient(configuration: config, transfer: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await offline.request("Activate", key: "TEST", machine: "mac")
            Issue.record("Expected network failure")
        } catch LicenseError.unavailable { }
    }

    @MainActor @Test func lockedPasteConsumesFilesWithoutImporting() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/beat.wav") as NSURL])
        let handler = AudioPasteHandler()
        handler.canImport = { false }
        var imported = false
        handler.onPaste = { _ in imported = true }
        #expect(handler.paste(from: pasteboard))
        #expect(!imported)
        pasteboard.clearContents()
        pasteboard.setString("TEST-KEY", forType: .string)
        #expect(!handler.paste(from: pasteboard))
    }

    @MainActor @Test func activationOfflineRestartRevocationAndRemoval() async throws {
        let fixture = try fixture()
        var payload = payload()
        payload["SignDate"] = Date().timeIntervalSince1970
        payload["Expires"] = Date().addingTimeInterval(86400).timeIntervalSince1970
        let response = try fixture.response(payload)
        var saved: LicenseKeychain.Receipt?
        let storage = LicensePersistence(read: { saved }, save: { saved = $0 }, remove: { saved = nil })
        var mode = "valid"
        var client = fixture.client
        client.transfer = { request in
            if mode == "offline" { throw URLError(.notConnectedToInternet) }
            let body: Data
            if mode == "blocked" { body = Data(#"{"result":1,"message":"Key is blocked"}"#.utf8) }
            else if request.url!.lastPathComponent == "Deactivate" { body = Data(#"{"result":0}"#.utf8) }
            else { body = response }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = LicenseService(makeClient: { client }, machine: { "mac" }, persistence: storage, allowsTestLicense: false)
        #expect(!service.isLicensed)
        await service.activate("  test-key  ")
        #expect(service.isLicensed)
        #expect(saved?.key == "TEST-KEY")
        mode = "offline"
        let restarted = LicenseService(makeClient: { client }, machine: { "mac" }, persistence: storage, allowsTestLicense: false)
        #expect(restarted.isLicensed)
        await restarted.refresh()
        #expect(restarted.isLicensed)
        await restarted.removeLicense()
        #expect(restarted.isLicensed)
        #expect(saved != nil)
        mode = "blocked"
        await restarted.refresh()
        #expect(!restarted.isLicensed)
        #expect(saved == nil)
        let afterRejection = LicenseService(makeClient: { client }, machine: { "mac" }, persistence: storage, allowsTestLicense: false)
        #expect(!afterRejection.isLicensed)
        mode = "valid"
        await afterRejection.activate("TEST-KEY")
        #expect(afterRejection.isLicensed)
        await afterRejection.removeLicense()
        #expect(!afterRejection.isLicensed)
        #expect(saved == nil)
    }

    @MainActor @Test func carloTestLicensePersistsAndRemovesWithoutNetwork() async throws {
        let suite = "BeatSnap-license-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = LicensePersistence(read: { nil }, save: { _ in Issue.record("Unexpected real receipt") },
                                         remove: { Issue.record("Unexpected real removal") })
        func service(enabled: Bool) -> LicenseService {
            LicenseService(makeClient: { throw LicenseError.unavailable }, persistence: storage,
                           allowsTestLicense: enabled, testDefaults: defaults)
        }
        let test = service(enabled: true)
        await test.activate("  carlo  ")
        #expect(test.isLicensed)
        #expect(test.isTestLicense)
        let restart = service(enabled: true)
        #expect(restart.isLicensed)
        await restart.refresh()
        #expect(restart.isLicensed)
        let production = service(enabled: false)
        #expect(!production.isLicensed)
        await production.activate("CARLO")
        #expect(!production.isLicensed)
        await restart.removeLicense()
        #expect(!restart.isLicensed)
        #expect(!service(enabled: true).isLicensed)
    }

    private func payload() -> [String: Any] {
        ["ProductId": 42, "Key": "TEST-KEY", "Expires": now.addingTimeInterval(30 * 86400).timeIntervalSince1970,
         "SignDate": now.timeIntervalSince1970, "Block": false, "MaxNoOfMachines": 1,
         "ActivatedMachines": [["Mid": "mac"]]]
    }

    private struct Fixture {
        let privateKey: SecKey
        let client: CryptolensClient
        func response(_ payload: [String: Any]) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                               data as CFData, nil)) as Data
            return try JSONSerialization.data(withJSONObject: [
                "result": 0, "licenseKey": data.base64EncodedString(), "signature": signature.base64EncodedString()
            ])
        }
    }

    private func fixture() throws -> Fixture {
        let key = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let data = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Decode Apple's PKCS#1 public representation to Cryptolens' XML public-key format.
        let bytes = [UInt8](data)
        var position = 1
        func length() -> Int {
            let first = Int(bytes[position]); position += 1
            if first < 128 { return first }
            var result = 0
            for _ in 0..<(first & 127) { result = result * 256 + Int(bytes[position]); position += 1 }
            return result
        }
        _ = length()
        func integer() -> Data {
            position += 1
            let count = length()
            var value = Data(bytes[position..<(position + count)])
            position += count
            if value.first == 0 { value.removeFirst() }
            return value
        }
        let modulus = integer().base64EncodedString()
        let exponent = integer().base64EncodedString()
        return Fixture(privateKey: key, client: CryptolensClient(configuration: LicenseConfiguration(
            productID: 42, accessToken: "test",
            rsaPublicKey: "<RSAKeyValue><Modulus>\(modulus)</Modulus><Exponent>\(exponent)</Exponent></RSAKeyValue>"
        )))
    }
}

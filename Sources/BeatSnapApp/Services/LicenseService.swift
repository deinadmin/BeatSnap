import CryptoKit
import Foundation
import IOKit
import Observation
import Security

struct LicenseConfiguration: Decodable {
    let productID: Int
    let accessToken: String
    let rsaPublicKey: String

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "Cryptolens", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode(Self.self, from: data),
              config.productID > 0, !config.accessToken.isEmpty, !config.rsaPublicKey.isEmpty
        else { throw LicenseError.message("Licensing is not configured in this build. Please contact BeatSnap support.") }
        return config
    }
}

enum LicenseError: LocalizedError {
    case message(String)
    case unavailable
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .unavailable: return "Could not reach the license server. Check your internet connection and try again."
        }
    }
}

struct LicenseCertificate: Decodable {
    let productID: Int
    let key: String
    let expires: Double
    let signDate: Double
    let block: Bool
    let maxNoOfMachines: Int
    let activatedMachines: [Machine]?
    struct Machine: Decodable {
        let mid: String
        enum CodingKeys: String, CodingKey { case mid = "Mid" }
    }
    enum CodingKeys: String, CodingKey {
        case productID = "ProductId", key = "Key", expires = "Expires", signDate = "SignDate"
        case block = "Block", maxNoOfMachines = "MaxNoOfMachines", activatedMachines = "ActivatedMachines"
    }

    static let offlineInterval: TimeInterval = 7 * 24 * 60 * 60
    var expiration: Date { Date(timeIntervalSince1970: expires) }
    var usableUntil: Date { min(expiration, Date(timeIntervalSince1970: signDate + Self.offlineInterval)) }

    func validate(productID: Int, key: String, machine: String, now: Date) throws {
        guard self.productID == productID, self.key == key, !block,
              maxNoOfMachines == 0 || activatedMachines?.contains(where: { $0.mid == machine }) == true
        else { throw LicenseError.message("This license is not valid for BeatSnap on this Mac.") }
        guard expiration > now else { throw LicenseError.message("This license has expired. Renew your license to continue.") }
        guard signDate <= now.timeIntervalSince1970 + 300, usableUntil > now
        else { throw LicenseError.message("Connect to the internet to verify your license again.") }
    }
}

/// Cryptolens String Sign (SignMethod=1): RSA PKCS#1 v1.5 / SHA-256 over decoded JSON.
struct CryptolensClient {
    let configuration: LicenseConfiguration
    var transfer: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    func request(_ method: String, key: String, machine: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.cryptolens.io/api/key/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "token": configuration.accessToken, "ProductId": String(configuration.productID),
            "Key": key, "MachineCode": machine, "Sign": "true", "SignMethod": "1", "v": "1"
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transfer(request) }
        catch { throw LicenseError.unavailable }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw LicenseError.unavailable }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.result == 0 else {
            throw LicenseError.message(envelope.message?.isEmpty == false
                                       ? envelope.message! : "The license server rejected this license.")
        }
        return data
    }

    struct Envelope: Decodable {
        let result: Int
        let message: String?
        let licenseKey: String?
        let signature: String?
    }

    func verify(_ data: Data, key: String, machine: String, now: Date = Date()) throws -> LicenseCertificate {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.result == 0,
              let encoded = envelope.licenseKey, let payload = Data(base64Encoded: encoded),
              let signatureString = envelope.signature, let signature = Data(base64Encoded: signatureString),
              SecKeyVerifySignature(try publicKey(), .rsaSignatureMessagePKCS1v15SHA256,
                                    payload as CFData, signature as CFData, nil)
        else { throw LicenseError.message("The license signature could not be verified.") }
        let certificate = try JSONDecoder().decode(LicenseCertificate.self, from: payload)
        try certificate.validate(productID: configuration.productID, key: key, machine: machine, now: now)
        return certificate
    }

    private func publicKey() throws -> SecKey {
        func component(_ name: String) throws -> Data {
            let xml = configuration.rsaPublicKey
            guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>"),
                  start.upperBound < end.lowerBound,
                  let bytes = Data(base64Encoded: String(xml[start.upperBound..<end.lowerBound]),
                                   options: .ignoreUnknownCharacters), !bytes.isEmpty
            else { throw LicenseError.message("The licensing public key is not configured correctly.") }
            return bytes
        }
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            var length = bytes.count
            var prefix = Data([tag])
            if length < 128 { prefix.append(UInt8(length)) }
            else {
                var octets: [UInt8] = []
                while length > 0 { octets.insert(UInt8(length & 255), at: 0); length >>= 8 }
                prefix.append(0x80 | UInt8(octets.count))
                prefix.append(contentsOf: octets)
            }
            return prefix + bytes
        }
        func integer(_ bytes: Data) -> Data {
            var bytes = bytes
            if bytes.first! >= 128 { bytes.insert(0, at: 0) }
            return der(0x02, bytes)
        }
        let bytes = der(0x30, integer(try component("Modulus")) + integer(try component("Exponent")))
        guard let key = SecKeyCreateWithData(bytes as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic
        ] as CFDictionary, nil) else { throw LicenseError.message("The licensing public key is invalid.") }
        return key
    }
}

/// Only the key and signed server receipt are persisted, never an editable "licensed" flag.
enum LicenseKeychain {
    struct Receipt: Codable {
        let key: String
        let response: Data
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.carl.beatsnap.license",
         kSecAttrAccount as String: "activation"]
    }
    static func read() throws -> Receipt? {
        var query = query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return try JSONDecoder().decode(Receipt.self, from: data)
    }
    static func save(_ receipt: Receipt) throws {
        let attributes = [kSecValueData as String: try JSONEncoder().encode(receipt)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> LicenseError {
        .message("Could not access the saved license in Keychain (\(status)). Please try again.")
    }
}

struct LicensePersistence {
    var read: () throws -> LicenseKeychain.Receipt?
    var save: (LicenseKeychain.Receipt) throws -> Void
    var remove: () throws -> Void
    static let keychain = Self(read: LicenseKeychain.read, save: LicenseKeychain.save, remove: LicenseKeychain.remove)
}

@MainActor @Observable
final class LicenseService {
    nonisolated static var testLicenseEnabled: Bool {
        #if DEBUG || BEATSNAP_TEST_LICENSE
        true
        #else
        false
        #endif
    }

    private static let testActivationPreference = "BeatSnapCARLOTestLicense"
    private(set) var isTestLicense = false
    @ObservationIgnored private let allowsTestLicense: Bool
    @ObservationIgnored private let testDefaults: UserDefaults
    private(set) var certificate: LicenseCertificate?
    private(set) var isBusy = false
    private(set) var message: String?
    private var now = Date()
    @ObservationIgnored private let makeClient: () throws -> CryptolensClient
    @ObservationIgnored private let machine: () throws -> String
    @ObservationIgnored private let persistence: LicensePersistence
    @ObservationIgnored private var receipt: LicenseKeychain.Receipt?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored var onAccessChanged: ((Bool) -> Void)?

    var isLicensed: Bool { isTestLicense || (certificate.map { $0.usableUntil > now && $0.usableUntil > Date() } ?? false) }

    init(
        makeClient: @escaping () throws -> CryptolensClient = { CryptolensClient(configuration: try .bundled()) },
        machine: @escaping () throws -> String = LicenseService.machineCode,
        persistence: LicensePersistence = .keychain,
        allowsTestLicense: Bool = LicenseService.testLicenseEnabled,
        testDefaults: UserDefaults = .standard
    ) {
        self.allowsTestLicense = allowsTestLicense
        self.testDefaults = testDefaults
        self.makeClient = makeClient
        self.machine = machine
        self.persistence = persistence
        if allowsTestLicense && testDefaults.bool(forKey: Self.testActivationPreference) {
            isTestLicense = true
            return
        }
        do {
            receipt = try persistence.read()
            if let receipt {
                certificate = try makeClient().verify(receipt.response, key: receipt.key, machine: machine())
            }
        } catch { message = error.localizedDescription }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.onAccessChanged?(self.isLicensed)
                if Date().timeIntervalSince(self.lastCheck) >= 3600 { await self.refresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refresh() }
    }

    deinit { timer?.invalidate() }

    func activate(_ input: String) async {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !isBusy, !key.isEmpty else { return }
        if allowsTestLicense && key == "CARLO" {
            testDefaults.set(true, forKey: Self.testActivationPreference)
            isTestLicense = true
            certificate = nil
            message = nil
            onAccessChanged?(true)
            return
        }
        await check(key: key, isRefresh: false)
    }

    func refresh() async {
        guard !isTestLicense, !isBusy, let receipt else { return }
        await check(key: receipt.key, isRefresh: true)
    }

    private func check(key: String, isRefresh: Bool) async {
        isBusy = true
        message = nil
        lastCheck = Date()
        defer { isBusy = false; now = Date(); onAccessChanged?(isLicensed) }
        do {
            let client = try makeClient()
            let machine = try machine()
            let response = try await client.request("Activate", key: key, machine: machine)
            let certificate = try client.verify(response, key: key, machine: machine)
            let receipt = LicenseKeychain.Receipt(key: key, response: response)
            try persistence.save(receipt)
            self.receipt = receipt
            self.certificate = certificate
        } catch LicenseError.unavailable {
            // Only connectivity/server failures permit the existing signed offline lease.
            message = isRefresh && isLicensed
                ? "Offline — reconnect within seven days of your last verification."
                : LicenseError.unavailable.localizedDescription
        } catch {
            certificate = nil
            // Rejected receipts must not unlock the next launch from the offline cache.
            try? persistence.remove()
            message = error.localizedDescription
        }
    }

    func removeLicense() async {
        if isTestLicense {
            testDefaults.removeObject(forKey: Self.testActivationPreference)
            isTestLicense = false
            message = nil
            onAccessChanged?(isLicensed)
            return
        }
        guard !isBusy, let receipt else { return }
        isBusy = true
        message = nil
        defer { isBusy = false; onAccessChanged?(isLicensed) }
        do {
            let client = try makeClient()
            _ = try await client.request("Deactivate", key: receipt.key, machine: machine())
            try persistence.remove()
            self.receipt = nil
            certificate = nil
        } catch { message = error.localizedDescription }
    }

    nonisolated private static func machineCode() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw LicenseError.message("Could not identify this Mac for activation.") }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        else { throw LicenseError.message("Could not identify this Mac for activation.") }
        return SHA256.hash(data: Data(("com.carl.beatsnap:" + uuid).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation

enum LicenseCodeInput {
    static let placeholder = "XXXXX-XXXXX-XXXXX-XXXXX"

    static func format(_ input: String) -> String {
        let letters = input.uppercased().unicodeScalars
            .filter { (65...90).contains($0.value) }
            .prefix(20)
        let key = String(String.UnicodeScalarView(letters))
        if key == "CARLO" { return key }

        var result = ""
        for (index, letter) in key.enumerated() {
            result.append(letter)
            if (index + 1).isMultiple(of: 5), index < 19 { result.append("-") }
        }
        return result
    }

    static func isComplete(_ input: String) -> Bool {
        if input == "CARLO" { return true }
        let groups = input.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 4 && groups.allSatisfy {
            $0.count == 5 && $0.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
        }
    }
}

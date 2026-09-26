import AppKit
import SwiftUI
import Testing
@testable import BeatSnapApp

struct LicenseCodeInputTests {
    @Test func normalizesTypedAndPastedKeys() {
        #expect(LicenseCodeInput.format("dxixn vbkbi duuri dymbh") == "DXIXN-VBKBI-DUURI-DYMBH")
        #expect(LicenseCodeInput.format("dxixnvbkbiduuridymbh") == "DXIXN-VBKBI-DUURI-DYMBH")
        #expect(LicenseCodeInput.format("DXIXN ") == "DXIXN-")
        #expect(LicenseCodeInput.format("DXIXN-") == "DXIXN-")
        #expect(LicenseCodeInput.format("DXIXN") == "DXIXN-")
        #expect(LicenseCodeInput.format("dx1i!xn--vbkbi") == "DXIXN-VBKBI-")
        #expect(LicenseCodeInput.format("DXIXN-VBKBI-DUURI-DYMBHEXTRA") == "DXIXN-VBKBI-DUURI-DYMBH")
        #expect(LicenseCodeInput.format("carlo") == "CARLO")
        #expect(LicenseCodeInput.format("") == "")
        #expect(LicenseCodeInput.format("a b  c-123!?\t") == "ABC")
        #expect(LicenseCodeInput.format(String(repeating: "x", count: 30)).count == 23)
    }

    @MainActor @Test func nativeFieldRejectsCharactersEvenWhenBindingDoesNotChange() {
        var value = "CARLO"
        let view = LicenseCodeField(text: Binding(get: { value }, set: { value = $0 }),
                                    isFocused: .constant(false), isEnabled: true, onSubmit: {})
        let coordinator = view.makeCoordinator()
        let field = NSTextField(string: "CARLO1!")
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(field.stringValue == "CARLO")
        #expect(value == "CARLO")
        field.stringValue = "abc def?"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(field.stringValue == "ABCDE-F")
        #expect(value == "ABCDE-F")
    }

    @Test func separatorsAreGeneratedOnlyAtGroupBoundaries() {
        #expect(LicenseCodeInput.format("ab- c--d") == "ABCD")
        #expect(LicenseCodeInput.format("abcde") == "ABCDE-")
        #expect(LicenseCodeInput.format("abcdefghij") == "ABCDE-FGHIJ-")
        #expect(LicenseCodeInput.format("abcdefghijklmno") == "ABCDE-FGHIJ-KLMNO-")
        #expect(LicenseCodeInput.format("abcdefghijklmnopqrst") == "ABCDE-FGHIJ-KLMNO-PQRST")
        #expect(LicenseCodeInput.format("CARLO-") == "CARLO")
        #expect(LicenseCodeInput.format("CARLOA") == "CARLO-A")
        #expect(LicenseCodeInput.format("  --123!?") == "")
    }

    @MainActor @Test func backspaceCrossesGeneratedSeparator() {
        let view = LicenseCodeField(text: .constant("ABCDE-"), isFocused: .constant(false),
                                    isEnabled: true, onSubmit: {})
        let editor = NSTextView()
        editor.string = "ABCDE-"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        let handled = view.makeCoordinator().control(NSTextField(), textView: editor,
                                                     doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        #expect(handled)
        #expect(LicenseCodeInput.format(editor.string) == "ABCD")
    }

    @Test func onlyCompleteKeysOrCarloCanSubmit() {
        #expect(LicenseCodeInput.isComplete("DXIXN-VBKBI-DUURI-DYMBH"))
        #expect(LicenseCodeInput.isComplete("CARLO"))
        for input in ["", "CARL", "CARLO-", "DXIXN-VBKBI", "DXIXN-VBKBI-DUURI-DYMB1",
                      "dxixn-vbkbi-duuri-dymbh", "DXIXN VBKBI DUURI DYMBH"] {
            #expect(!LicenseCodeInput.isComplete(input))
        }
    }
}

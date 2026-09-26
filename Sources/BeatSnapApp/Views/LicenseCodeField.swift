import AppKit
import SwiftUI

/// Correct the native field editor as well as the binding. A SwiftUI binding setter alone
/// can leave rejected characters visible when the normalized state has not changed.
struct LicenseCodeField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.placeholderString = LicenseCodeInput.placeholder
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("License code")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        if field.stringValue != text { field.stringValue = text }
        if isFocused && isEnabled && field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator, coordinator.parent.isFocused,
                      coordinator.parent.isEnabled, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LicenseCodeField
        init(_ parent: LicenseCodeField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
            }
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let editor = field.currentEditor()
            let raw = editor?.string ?? field.stringValue
            let formatted = LicenseCodeInput.format(raw)
            if raw != formatted {
                let caret = editor?.selectedRange.location ?? (raw as NSString).length
                let prefix = (raw as NSString).substring(to: min(caret, (raw as NSString).length))
                field.stringValue = formatted
                editor?.string = formatted
                editor?.selectedRange = NSRange(location: min(LicenseCodeInput.format(prefix).utf16.count,
                                                              formatted.utf16.count), length: 0)
            }
            parent.text = formatted
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Backspace across an automatic separator must remove the preceding letter
            // too; deleting only the separator would immediately regenerate it.
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                let selection = textView.selectedRange()
                let value = textView.string as NSString
                if selection.length == 0, selection.location >= 2,
                   selection.location <= value.length,
                   value.substring(with: NSRange(location: selection.location - 1, length: 1)) == "-" {
                    textView.insertText("", replacementRange: NSRange(location: selection.location - 2, length: 2))
                    return true
                }
                return false
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

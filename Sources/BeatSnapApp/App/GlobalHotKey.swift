import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey registered through Carbon's hotkey API.
///
/// Chosen over an `NSEvent` global monitor because it needs no Accessibility permission and
/// still fires while another app (a DAW) is frontmost.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1

    private let identifier: UInt32

    /// - Parameters:
    ///   - keyCode: A virtual key code, e.g. `kVK_ANSI_B`.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | optionKey`.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.identifier = Self.nextID
        Self.nextID += 1
        Self.registry[identifier] = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            GlobalHotKey.registry[hotKeyID.id]?.handler()
            return noErr
        }

        var handlerRef: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &handlerRef)
        self.eventHandler = handlerRef

        let hotKeyID = EventHotKeyID(signature: OSType(0x42534E50), id: identifier) // 'BSNP'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else {
            Self.registry[identifier] = nil
            return nil
        }
        self.hotKeyRef = reference
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Self.registry[identifier] = nil
    }

    /// Command + Option + Control + Shift (the "hyper" combination).
    static var hyperModifiers: UInt32 {
        UInt32(cmdKey | optionKey | controlKey | shiftKey)
    }
}

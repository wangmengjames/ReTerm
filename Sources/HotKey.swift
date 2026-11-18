import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut: Control-Option-Command-T reopens the last closed tab.
enum HotKey {
    static var action: (() -> Void)?
    private static var reference: EventHotKeyRef?

    static let display = "⌃⌥⌘T"

    /// Returns false if another app already owns the shortcut.
    @discardableResult
    static func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5254_524D), id: 1)   // "RTRM"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }
}

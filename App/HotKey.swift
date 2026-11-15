// mTAPES — raccourci global (⌥⌘R) par Carbon : aucune autorisation requise.
import Carbon.HIToolbox
import Foundation

enum HotKey {
    nonisolated(unsafe) private static var action: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D544150), id: 1)   // « MTAP »
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

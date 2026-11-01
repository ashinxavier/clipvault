import Carbon
import Foundation

public enum ShortcutPreset: String, CaseIterable, Identifiable {
    case optionV
    case controlOptionV

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .optionV: "Option + V"
        case .controlOptionV: "Control + Option + V"
        }
    }

    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .optionV: UInt32(optionKey)
        case .controlOptionV: UInt32(controlKey | optionKey)
        }
    }
}

public final class GlobalShortcutManager {
    private static let signature: OSType = 0x43564C54 // CVLT
    private static let identifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    public var onShortcut: (() -> Void)?

    public init() {}

    deinit { unregister() }

    @discardableResult
    public func register(_ preset: ShortcutPreset) -> OSStatus {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerProcPtr = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            guard status == noErr,
                  pressedID.signature == GlobalShortcutManager.signature,
                  pressedID.id == GlobalShortcutManager.identifier else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<GlobalShortcutManager>.fromOpaque(userData)
                .takeUnretainedValue()
                .onShortcut?()
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )
        guard installStatus == noErr else { return installStatus }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            preset.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if registerStatus != noErr { unregister() }
        return registerStatus
    }

    public func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}

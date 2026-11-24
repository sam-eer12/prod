import Carbon
import Foundation

private final class HotkeyCallbackBox: Sendable {
    let onTrigger: @MainActor @Sendable () -> Void

    init(onTrigger: @escaping @MainActor @Sendable () -> Void) {
        self.onTrigger = onTrigger
    }
}

private final class CarbonHotkeyRegistrationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var retainedBox: Unmanaged<HotkeyCallbackBox>?

    func store(
        hotKeyRef: EventHotKeyRef?,
        eventHandlerRef: EventHandlerRef?,
        retainedBox: Unmanaged<HotkeyCallbackBox>?
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.hotKeyRef = hotKeyRef
        self.eventHandlerRef = eventHandlerRef
        self.retainedBox = retainedBox
    }

    func unregister() {
        lock.lock()
        let hotKey = hotKeyRef
        let handler = eventHandlerRef
        let box = retainedBox
        hotKeyRef = nil
        eventHandlerRef = nil
        retainedBox = nil
        lock.unlock()

        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        box?.release()
    }
}

private let brokCarbonHotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr,
          hotKeyID.signature == GlobalHotkeyManager.hotKeySignature,
          hotKeyID.id == GlobalHotkeyManager.hotKeyIDValue else {
        return OSStatus(eventNotHandledErr)
    }

    let box = Unmanaged<HotkeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        box.onTrigger()
    }
    return noErr
}

/// Registers and manages the global `Cmd+Shift+B` Carbon hotkey to toggle or reveal Brok Bot.
@MainActor
final class GlobalHotkeyManager: ObservableObject {
    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var registrationError: String?

    nonisolated static let hotKeySignature: OSType = 0x42524F4B // "BROK"
    nonisolated static let hotKeyIDValue: UInt32 = 1
    nonisolated static let keyCodeB: UInt32 = UInt32(kVK_ANSI_B) // 11
    nonisolated static let modifierFlags: UInt32 = UInt32(cmdKey | shiftKey)

    private let registrationHandle = CarbonHotkeyRegistrationHandle()

    deinit {
        let handle = registrationHandle
        if Thread.isMainThread {
            handle.unregister()
        } else {
            DispatchQueue.main.async {
                handle.unregister()
            }
        }
    }

    /// Registers the global `Cmd+Shift+B` shortcut, replacing any previous registration.
    func registerCmdShiftB(handler: @escaping @MainActor @Sendable () -> Void) {
        unregister()

        let box = HotkeyCallbackBox(onTrigger: handler)
        let retainedBox = Unmanaged.passRetained(box)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            brokCarbonHotKeyHandler,
            1,
            &eventType,
            retainedBox.toOpaque(),
            &installedHandler
        )

        guard handlerStatus == noErr, let installedHandler else {
            retainedBox.release()
            isRegistered = false
            registrationError = "Failed to install Carbon hotkey handler (status \(handlerStatus))."
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyIDValue
        )

        var registeredHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            Self.keyCodeB,
            Self.modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registerStatus == noErr, let registeredHotKey else {
            RemoveEventHandler(installedHandler)
            retainedBox.release()
            isRegistered = false
            registrationError = "Failed to register Cmd+Shift+B hotkey (status \(registerStatus))."
            return
        }

        registrationHandle.store(
            hotKeyRef: registeredHotKey,
            eventHandlerRef: installedHandler,
            retainedBox: retainedBox
        )
        isRegistered = true
        registrationError = nil
    }

    /// Unregisters the global hotkey and tears down the Carbon event handler.
    func unregister() {
        registrationHandle.unregister()
        isRegistered = false
    }
}

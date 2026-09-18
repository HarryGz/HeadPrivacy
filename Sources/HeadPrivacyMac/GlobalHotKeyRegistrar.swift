import Carbon
import HeadPrivacyCore

@MainActor
public protocol GlobalHotKeyRegistering: AnyObject {
    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @MainActor () -> Void) throws
    func unregister()
}

public enum HotKeyRegistrationError: Error, Equatable {
    case modifierRequired
    case unsupportedKey(String)
    case system(OSStatus)
}

/// Carbon registers a shortcut directly and never requests Accessibility permission.
@MainActor
public final class GlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    private let system: any HotKeySystem
    private var installedHandler = false
    private var nextID: UInt32 = 0
    private var activeID: UInt32?
    private var handler: (@MainActor () -> Void)?

    public convenience init() { self.init(system: CarbonHotKeySystem()) }

    init(system: any HotKeySystem) { self.system = system }

    /// Keys are case-insensitive ANSI physical positions A–Z, 0–9, Space, Return, Tab,
    /// Escape, and arrow keys. Invalid descriptors preserve the current registration.
    /// A system failure while replacing a valid descriptor leaves no active shortcut.
    public func register(_ descriptor: HotkeyDescriptor, handler: @escaping @MainActor () -> Void) throws {
        guard !descriptor.modifiers.isEmpty else { throw HotKeyRegistrationError.modifierRequired }
        guard let keyCode = Self.keyCodes[descriptor.key.uppercased()] else {
            throw HotKeyRegistrationError.unsupportedKey(descriptor.key)
        }
        var modifiers: UInt32 = 0
        for modifier in descriptor.modifiers {
            switch modifier {
            case .control: modifiers |= UInt32(controlKey)
            case .option: modifiers |= UInt32(optionKey)
            case .command: modifiers |= UInt32(cmdKey)
            case .shift: modifiers |= UInt32(shiftKey)
            }
        }
        if !installedHandler {
            try system.installHandler { [weak self] id in
                Task { @MainActor [weak self] in
                    guard let self, self.activeID == id else { return }
                    self.handler?()
                }
            }
            installedHandler = true
        }
        unregister()
        nextID &+= 1
        try system.register(keyCode: UInt32(keyCode), modifiers: modifiers, id: nextID)
        activeID = nextID
        self.handler = handler
    }

    public func unregister() {
        guard activeID != nil else { return }
        // Invalidate queued main-actor deliveries before releasing the OS registration.
        activeID = nil
        handler = nil
        system.unregister()
    }

    isolated deinit {
        if activeID != nil { system.unregister() }
        if installedHandler { system.removeHandler() }
    }

    private static let keyCodes = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
        "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
        "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
        "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "SPACE": kVK_Space, "RETURN": kVK_Return, "TAB": kVK_Tab, "ESCAPE": kVK_Escape,
        "LEFT": kVK_LeftArrow, "RIGHT": kVK_RightArrow, "UP": kVK_UpArrow, "DOWN": kVK_DownArrow,
    ]
}

@MainActor
protocol HotKeySystem: AnyObject {
    func installHandler(_ handler: @escaping @Sendable (UInt32) -> Void) throws
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws
    func unregister()
    func removeHandler()
}

private let hotKeySignature: OSType = 0x48505256 // HPRV

private final class HotKeyCallback: Sendable {
    let invoke: @Sendable (UInt32) -> Void
    init(_ invoke: @escaping @Sendable (UInt32) -> Void) { self.invoke = invoke }
}

@MainActor
private final class CarbonHotKeySystem: HotKeySystem {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var callback: HotKeyCallback?

    func installHandler(_ handler: @escaping @Sendable (UInt32) -> Void) throws {
        guard eventHandler == nil else { return }
        let callback = HotKeyCallback(handler)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == hotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<HotKeyCallback>.fromOpaque(context).takeUnretainedValue().invoke(identifier.id)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(callback).toOpaque(), &eventHandler)
        guard status == noErr else { throw HotKeyRegistrationError.system(status) }
        self.callback = callback
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        let status = RegisterEventHotKey(keyCode, modifiers,
            EventHotKeyID(signature: hotKeySignature, id: id), GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { throw HotKeyRegistrationError.system(status) }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    func removeHandler() {
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        // Application Carbon events and removal run on the main thread. Retain the context
        // until handler removal; asynchronous deliveries capture only the ID and weak registrar.
        callback = nil
    }

    isolated deinit {
        unregister()
        removeHandler()
    }
}

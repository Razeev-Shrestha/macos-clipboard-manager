import AppKit
import Carbon.HIToolbox

private let globalClipboardHotKeySignature: OSType = 0x434C4950 // "CLIP"
private let globalClipboardHotKeyIdentifier: UInt32 = 1

/// The persisted native key-code and modifier representation used by Carbon.
/// The value is intentionally small and Codable so a future recorder can replace
/// the default without exposing Carbon implementation details to the view layer.
public struct GlobalClipboardShortcutConfiguration: Codable, Equatable, Sendable {
    public static let `default` = GlobalClipboardShortcutConfiguration(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        let supportedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return keyCode <= 127
            && modifiers != 0
            && (modifiers & ~supportedModifiers) == 0
    }
}

// The token is unchecked-Sendable because its mutable generation/active state
// is always protected by `lock`. `owner` is initialized before registration
// and read only on MainActor; registration, unregistration, and teardown are
// serialized by GlobalClipboardShortcut's MainActor isolation.
private final class GlobalClipboardHotKeyToken: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false
    weak var owner: GlobalClipboardShortcut?

    func activate() {
        lock.lock()
        generation &+= 1
        active = true
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        generation &+= 1
        active = false
        lock.unlock()
    }

    func snapshot() -> (generation: UInt64, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (generation, active)
    }

    func isCurrent(generation expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && generation == expectedGeneration
    }
}

private func globalClipboardHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var pressedID = EventHotKeyID()
    var actualSize = 0
    let parameterStatus = withUnsafeMutableBytes(of: &pressedID) { bytes in
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            bytes.count,
            &actualSize,
            bytes.baseAddress
        )
    }
    guard parameterStatus == noErr,
          pressedID.signature == globalClipboardHotKeySignature,
          pressedID.id == globalClipboardHotKeyIdentifier
    else {
        return OSStatus(eventNotHandledErr)
    }

    let token = Unmanaged<GlobalClipboardHotKeyToken>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let snapshot = token.snapshot()
    guard snapshot.active else {
        return OSStatus(eventNotHandledErr)
    }

    Task { @MainActor [weak token] in
        guard let token,
              token.isCurrent(generation: snapshot.generation),
              let shortcut = token.owner else {
            return
        }
        shortcut.onPressed?()
    }
    return noErr
}

/// Errors returned when the system cannot install the clipboard shortcut.
///
/// `RegisterEventHotKey` is a system hot-key registration API. It does not
/// install an event tap and therefore does not require Accessibility or Input
/// Monitoring permission. The operating-system status is retained so the host
/// can surface a conflict or another registration failure.
public enum GlobalClipboardShortcutError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case eventHandlerInstallationFailed(status: Int32)
    case registrationFailed(status: Int32)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "The global shortcut configuration is invalid."
        case let .eventHandlerInstallationFailed(status):
            "Unable to install the global shortcut event handler (status \(status))."
        case let .registrationFailed(status):
            "Unable to register the global shortcut (status \(status))."
        }
    }
}

/// Registers the app-wide shortcut without an event tap or Accessibility permission.
@MainActor
public final class GlobalClipboardShortcut {
    public var onPressed: (() -> Void)?
    public let configuration: GlobalClipboardShortcutConfiguration

    private let hotKeyID = EventHotKeyID(
        signature: globalClipboardHotKeySignature,
        id: globalClipboardHotKeyIdentifier
    )
    private let callbackToken: GlobalClipboardHotKeyToken
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public init(configuration: GlobalClipboardShortcutConfiguration = .default) {
        self.configuration = configuration
        callbackToken = GlobalClipboardHotKeyToken()
        callbackToken.owner = self
    }

    isolated deinit {
        callbackToken.deactivate()
        if let hotKeyRef {
            _ = UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            _ = RemoveEventHandler(eventHandlerRef)
        }
    }

    /// Registers the configured shortcut. Repeated calls are idempotent.
    public func register() throws {
        guard hotKeyRef == nil else {
            return
        }
        guard configuration.isValid else {
            throw GlobalClipboardShortcutError.invalidConfiguration
        }

        var newEventHandlerRef: EventHandlerRef?
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let eventHandlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalClipboardHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(callbackToken).toOpaque(),
            &newEventHandlerRef
        )
        guard eventHandlerStatus == noErr, let newEventHandlerRef else {
            throw GlobalClipboardShortcutError.eventHandlerInstallationFailed(
                status: Int32(eventHandlerStatus)
            )
        }

        var newHotKeyRef: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &newHotKeyRef
        )
        guard registrationStatus == noErr, let newHotKeyRef else {
            _ = RemoveEventHandler(newEventHandlerRef)
            throw GlobalClipboardShortcutError.registrationFailed(
                status: Int32(registrationStatus)
            )
        }

        callbackToken.activate()
        eventHandlerRef = newEventHandlerRef
        hotKeyRef = newHotKeyRef
    }

    /// Removes the system shortcut and its application event handler.
    public func unregister() {
        callbackToken.deactivate()
        if let hotKeyRef {
            _ = UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            _ = RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}

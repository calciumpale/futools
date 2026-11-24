import AppKit
import Carbon

struct HotKey: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultValue = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "Space"
    )

    static let compactDefaultValue = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        keyLabel: "Space"
    )

    static let compactLegacyFallback = HotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        keyLabel: "Space"
    )

    private static let modifierKeys: [(appKit: NSEvent.ModifierFlags, carbon: UInt32, label: String)] = [
        (.control, UInt32(controlKey), "⌃"),
        (.option, UInt32(optionKey), "⌥"),
        (.shift, UInt32(shiftKey), "⇧"),
        (.command, UInt32(cmdKey), "⌘")
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "↵", kVK_ANSI_KeypadEnter: "⌤",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
        kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
        kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20"
    ]

    private static let standardCommandKeys = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ,`+-=0123456789".map(String.init))

    var display: String {
        Self.modifierKeys.compactMap { modifier in
            modifiers & modifier.carbon == 0 ? nil : modifier.label
        }.joined() + keyLabel
    }

    static func == (lhs: HotKey, rhs: HotKey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    static func capture(_ event: NSEvent) -> HotKey? {
        guard event.type == .keyDown, !event.isARepeat, event.keyCode != kVK_Escape else { return nil }

        let modifiers = modifierKeys.reduce(UInt32(0)) { result, modifier in
            event.modifierFlags.contains(modifier.appKit) ? result | modifier.carbon : result
        }
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }

        let keyCode = Int(event.keyCode)
        let keyLabel: String
        if let label = specialKeys[keyCode] {
            keyLabel = label
        } else if let character = [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers]
            .compactMap({ $0?.first })
            .first(where: { character in
                !character.isWhitespace
                    && character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }) {
            keyLabel = character.uppercased()
        } else {
            return nil
        }

        // Keep the usual single-Command editing and window shortcuts available to the target app.
        if modifiers == UInt32(cmdKey), standardCommandKeys.contains(keyLabel) { return nil }

        return HotKey(keyCode: UInt32(keyCode), modifiers: modifiers, keyLabel: keyLabel)
    }
}

@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x50444F43 // PDOC
    private static let registrations = NSMapTable<NSNumber, GlobalHotKey>.strongToWeakObjects()
    private static var eventHandler: EventHandlerRef?
    private static var lastRegistrationID: UInt32 = 0

    private let onPress: () -> Void
    private var registration: EventHotKeyRef?
    private var registrationID: UInt32?
    private var shortcut: HotKey?
    private var keyIsDown = false

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
    }

    func register(_ shortcut: HotKey) -> Bool {
        if self.shortcut == shortcut { return true }
        guard Self.installHandlerIfNeeded() else { return false }

        Self.lastRegistrationID &+= 1
        let nextID = Self.lastRegistrationID
        var nextRegistration: EventHotKeyRef?
        let result = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: nextID),
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &nextRegistration
        )
        guard result == noErr, let nextRegistration else { return false }

        unregister()
        registration = nextRegistration
        registrationID = nextID
        self.shortcut = shortcut
        Self.registrations.setObject(self, forKey: NSNumber(value: nextID))
        return true
    }

    func unregister() {
        if let registrationID {
            Self.registrations.removeObject(forKey: NSNumber(value: registrationID))
        }
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        registrationID = nil
        shortcut = nil
        keyIsDown = false
    }

    private static func installHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }

        let eventTypes = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
                // The one shared handler runs on AppKit's main-thread application event target.
                return MainActor.assumeIsolated { GlobalHotKey.route(event) }
            },
            eventTypes.count,
            eventTypes,
            nil,
            &eventHandler
        )
        return result == noErr
    }

    private static func route(_ event: EventRef) -> OSStatus {
        var incoming = EventHotKeyID()
        let result = GetEventParameter(
            event,
            OSType(kEventParamDirectObject),
            OSType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &incoming
        )
        guard result == noErr, incoming.signature == signature,
              let hotKey = registrations.object(forKey: NSNumber(value: incoming.id)) else {
            return OSStatus(eventNotHandledErr)
        }
        return hotKey.handle(kind: GetEventKind(event))
    }

    private func handle(kind: UInt32) -> OSStatus {
        if kind == UInt32(kEventHotKeyReleased) {
            keyIsDown = false
        } else if kind == UInt32(kEventHotKeyPressed) {
            if !keyIsDown {
                keyIsDown = true
                onPress()
            }
        } else {
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}

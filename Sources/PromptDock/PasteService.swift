import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

enum PasteOutcome: Equatable {
    case pasted
    case copiedNoPermission
    case copiedNoTarget
    case copiedTargetChanged
    case copiedTerminal
    case targetLostFocus
    case failed
}

@MainActor
final class PasteService {
    enum Destination { case standard, conversation }

    private enum Payload {
        case text(String)
        case attachment(URL)
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "org.tabby", "co.zeit.hyper"
    ]

    private var isPasting = false

    static var hasPermission: Bool {
        CGPreflightPostEventAccess()
    }

    static func requestPermission() {
        guard !hasPermission else { return }
        guard !CGRequestPostEventAccess(), let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func paste(_ text: String, into app: NSRunningApplication?,
               targetIsFocused: (@MainActor () -> Bool)? = nil,
               destination: Destination = .standard) async -> PasteOutcome {
        guard !text.isEmpty else { return .failed }
        return await paste(.text(text), into: app, targetIsFocused: targetIsFocused, destination: destination)
    }

    func pasteAttachment(_ url: URL, into app: NSRunningApplication,
                         targetIsFocused: @escaping @MainActor () -> Bool) async -> PasteOutcome {
        guard let localURL = localAttachmentURL(url) else { return .failed }
        return await paste(.attachment(localURL), into: app, targetIsFocused: targetIsFocused, destination: .conversation)
    }

    private func paste(_ payload: Payload, into app: NSRunningApplication?,
                       targetIsFocused: (@MainActor () -> Bool)?, destination: Destination) async -> PasteOutcome {
        guard !isPasting else { return .failed }
        isPasting = true
        defer { isPasting = false }

        let board = NSPasteboard.general
        let allowCopyFallback = destination == .standard
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if targetIsFocused != nil { return .targetLostFocus }
            return allowCopyFallback ? copy(payload, to: board, otherwise: .copiedNoTarget) : .failed
        }
        guard targetIsFocused?() != false else { return .targetLostFocus }
        if case let .text(text) = payload, let bundleIdentifier = app.bundleIdentifier,
           Self.terminalBundleIdentifiers.contains(bundleIdentifier),
           text.rangeOfCharacter(from: .newlines) != nil {
            // A shell without bracketed paste can interpret pasted newlines as submissions.
            return allowCopyFallback ? copy(payload, to: board, otherwise: .copiedTerminal) : .failed
        }
        guard Self.hasPermission else {
            return allowCopyFallback ? copy(payload, to: board, otherwise: .copiedNoPermission) : .failed
        }

        // Give the dismissed panel time to return keyboard focus to the original app.
        do { try await Task.sleep(for: .milliseconds(90)) } catch { return .failed }

        let pid = app.processIdentifier
        guard isFrontmost(pid) else {
            if targetIsFocused != nil { return .targetLostFocus }
            return allowCopyFallback ? copy(payload, to: board, otherwise: .copiedTargetChanged) : .failed
        }
        guard targetIsFocused?() != false else { return .targetLostFocus }
        let keyCode = pasteKeyCode()
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return .failed
        }

        let previousChange = board.changeCount
        let previousItems = snapshot(board)
        let canRestore = board.changeCount == previousChange
        guard targetIsFocused?() != false else { return .targetLostFocus }
        guard let pasteChange = write(payload, to: board) else { return .failed }
        if targetIsFocused?() == false {
            if canRestore, let previousItems { restore(previousItems, on: board, ifUnchangedSince: pasteChange) }
            return .targetLostFocus
        }
        guard isFrontmost(pid) else {
            if targetIsFocused != nil || !allowCopyFallback {
                if canRestore, let previousItems { restore(previousItems, on: board, ifUnchangedSince: pasteChange) }
                return .targetLostFocus
            }
            return .copiedTargetChanged
        }
        guard Self.hasPermission else {
            if allowCopyFallback { return .copiedNoPermission }
            if canRestore, let previousItems { restore(previousItems, on: board, ifUnchangedSince: pasteChange) }
            return .failed
        }
        guard board.changeCount == pasteChange else { return .failed }

        let menuItem = destination == .conversation ? pasteMenuItem(pid: pid) : nil
        let outcome: PasteOutcome
        if !isFrontmost(pid) || targetIsFocused?() == false {
            outcome = .targetLostFocus
        } else if board.changeCount != pasteChange {
            outcome = .failed
        } else {
            let menuResult = menuItem.map { AXUIElementPerformAction($0, kAXPressAction as CFString) }
            switch menuResult {
            case .success:
                outcome = .pasted
            case .cannotComplete:
                // An AX timeout can leave the action in flight. A second paste may duplicate the text.
                outcome = .failed
            default:
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.postToPid(pid)
                keyUp.postToPid(pid)
                outcome = .pasted
            }
        }

        if canRestore, let previousItems {
            // The target handles Cmd+V asynchronously. Restore only while our temporary item is current.
            if outcome != .targetLostFocus { try? await Task.sleep(for: .milliseconds(650)) }
            restore(previousItems, on: board, ifUnchangedSince: pasteChange)
        }
        return outcome
    }

    private func pasteMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)

        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            AXUIElementSetMessagingTimeout(element, 0.15)
            return value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }

        guard let bar = value(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        let editTitles = ["编辑", "編輯", "Edit"]
        let pasteTitles = ["粘贴", "貼上", "貼上文字", "Paste"]
        for menu in children(bar as! AXUIElement) {
            guard let title = value(menu, kAXTitleAttribute) as? String, editTitles.contains(title) else { continue }
            for item in children(menu).flatMap(children) {
                guard let title = value(item, kAXTitleAttribute) as? String, pasteTitles.contains(title),
                      value(item, kAXEnabledAttribute) as? Bool == true else { continue }
                return item
            }
        }
        return nil
    }

    private func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func pasteKeyCode() -> CGKeyCode {
        let ansiV = CGKeyCode(kVK_ANSI_V)

        func commandCharacter(for keyCode: CGKeyCode) -> String? {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: keyCode
            )
            return event?.characters(byApplyingModifiers: .command)?.lowercased()
        }

        // Most layouts translate the physical V key directly. Search only if it maps to another key.
        guard let mappedCharacter = commandCharacter(for: ansiV), mappedCharacter != "v" else { return ansiV }
        let keyboardCodes: Range<CGKeyCode> = 0..<128
        return keyboardCodes.first { $0 != ansiV && commandCharacter(for: $0) == "v" } ?? ansiV
    }

    private func localAttachmentURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        if let host = url.host, !host.isEmpty && host.lowercased() != "localhost" { return nil }
        let localURL = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
        guard let values = try? localURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .volumeIsLocalKey]),
              values.isRegularFile == true, values.isReadable == true, values.volumeIsLocal == true else { return nil }
        return localURL
    }

    private func copy(_ payload: Payload, to board: NSPasteboard, otherwise outcome: PasteOutcome) -> PasteOutcome {
        write(payload, to: board) != nil ? outcome : .failed
    }

    private func write(_ payload: Payload, to board: NSPasteboard) -> Int? {
        let change: Int
        switch payload {
        case .text(let text):
            change = board.declareTypes([.string], owner: nil)
            guard board.setString(text, forType: .string) else { return nil }
        case .attachment(let url):
            guard let currentURL = localAttachmentURL(url), currentURL == url else { return nil }
            change = board.clearContents()
            guard board.writeObjects([url as NSURL]) else { return nil }
        }
        return board.changeCount == change ? change : nil
    }

    private func restore(_ items: [NSPasteboardItem], on board: NSPasteboard, ifUnchangedSince change: Int) {
        guard board.changeCount == change else { return }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }

    private func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem]? {
        // A default/ask read can raise a system alert, taking focus from the intended input.
        if #available(macOS 15.4, *), board.accessBehavior != .alwaysAllow {
            return nil
        }

        guard let items = board.pasteboardItems else { return nil }
        var copies: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                // A pasteboard file promise cannot be recreated from its serialized representation.
                let identifier = type.rawValue.lowercased()
                guard !identifier.contains("filepromise"), !identifier.contains("promised-file"),
                      let data = item.data(forType: type), copy.setData(data, forType: type) else { return nil }
            }
            copies.append(copy)
        }
        return copies
    }
}

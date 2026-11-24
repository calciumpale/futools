import AppKit
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
               targetIsFocused: (@MainActor () -> Bool)? = nil) async -> PasteOutcome {
        guard !text.isEmpty, !isPasting else { return .failed }
        isPasting = true
        defer { isPasting = false }

        let board = NSPasteboard.general
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if targetIsFocused != nil { return .targetLostFocus }
            return copy(text, to: board, otherwise: .copiedNoTarget)
        }
        guard targetIsFocused?() != false else { return .targetLostFocus }
        if let bundleIdentifier = app.bundleIdentifier,
           Self.terminalBundleIdentifiers.contains(bundleIdentifier),
           text.rangeOfCharacter(from: .newlines) != nil {
            // A shell without bracketed paste can interpret pasted newlines as submissions.
            return copy(text, to: board, otherwise: .copiedTerminal)
        }
        guard Self.hasPermission else {
            return copy(text, to: board, otherwise: .copiedNoPermission)
        }

        // Give the dismissed panel time to return keyboard focus to the original app.
        do { try await Task.sleep(for: .milliseconds(90)) } catch { return .failed }

        let pid = app.processIdentifier
        guard isFrontmost(pid) else {
            if targetIsFocused != nil { return .targetLostFocus }
            return copy(text, to: board, otherwise: .copiedTargetChanged)
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
        guard let pasteChange = write(text, to: board) else { return .failed }
        if targetIsFocused?() == false {
            if canRestore, let previousItems { restore(previousItems, on: board, ifUnchangedSince: pasteChange) }
            return .targetLostFocus
        }
        guard isFrontmost(pid) else {
            if targetIsFocused != nil {
                if canRestore, let previousItems { restore(previousItems, on: board, ifUnchangedSince: pasteChange) }
                return .targetLostFocus
            }
            return .copiedTargetChanged
        }
        guard Self.hasPermission else { return .copiedNoPermission }
        guard board.changeCount == pasteChange else { return .failed }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        if canRestore, let previousItems {
            // The target handles Cmd+V asynchronously. Restore only while our temporary item is current.
            try? await Task.sleep(for: .milliseconds(650))
            restore(previousItems, on: board, ifUnchangedSince: pasteChange)
        }
        return .pasted
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

    private func copy(_ text: String, to board: NSPasteboard, otherwise outcome: PasteOutcome) -> PasteOutcome {
        write(text, to: board) != nil ? outcome : .failed
    }

    private func write(_ text: String, to board: NSPasteboard) -> Int? {
        let change = board.declareTypes([.string], owner: nil)
        guard board.setString(text, forType: .string), board.changeCount == change else { return nil }
        return change
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

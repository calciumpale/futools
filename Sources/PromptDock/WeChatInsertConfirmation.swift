import AppKit
import CoreGraphics

@MainActor
final class WeChatInsertConfirmation {
    private let clock = ContinuousClock()
    private var waiting: Waiting?
    private var mouseNumber: Int64?
    private var inputMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var timeout: Task<Void, Never>?

    deinit {
        timeout?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    @discardableResult
    func start(pid: pid_t, windowFrame: CGRect, composerFrame: CGRect, focusPoint: CGPoint,
               onComplete: @escaping (Bool) -> Void) -> Bool {
        cancel()
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier, Self.isFrontmost(pid),
              CGPreflightPostEventAccess(), NSEvent.pressedMouseButtons == 0,
              Self.valid(windowFrame), Self.valid(composerFrame), windowFrame.contains(composerFrame),
              composerFrame.contains(focusPoint),
              let windows = Self.visibleWindows(),
              let window = Self.uniqueTarget(in: windows, pid: pid, frame: windowFrame),
              window.frame.contains(composerFrame),
              Self.hitsTarget(focusPoint, target: window, windows: windows),
              let source = CGEventSource(stateID: .privateState) else { return false }

        let id = UUID()
        let marker = Int64.random(in: 1...Int64.max)
        let deadline = clock.now.advanced(by: .seconds(1))
        let armedAt = ProcessInfo.processInfo.systemUptime
        source.localEventsSuppressionInterval = 0
        source.userData = marker
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: focusPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: focusPoint, mouseButton: .left) else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }

        let inputs: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                             .otherMouseDown, .mouseMoved, .keyDown, .flagsChanged, .scrollWheel]
        guard let inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: inputs, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event, for: id) }
        }) else { return false }
        self.inputMonitor = inputMonitor
        waiting = Waiting(id: id, target: window, point: focusPoint, marker: marker, deadline: deadline,
                          armedAt: armedAt, onComplete: onComplete)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.waiting?.id == id else { return }
                let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if !Self.isFrontmost(pid) || (activated.map { $0.processIdentifier != pid } ?? false) {
                    self.complete(false)
                }
            }
        }
        timeout = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, self.waiting?.id == id else { return }
            self.complete(false)
        }

        guard Self.isFrontmost(pid), NSEvent.pressedMouseButtons == 0, let current = Self.visibleWindows(),
              Self.hitsTarget(focusPoint, target: window, windows: current) else {
            cancel()
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func cancel() {
        waiting = nil
        mouseNumber = nil
        timeout?.cancel()
        timeout = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func receive(_ event: NSEvent, for id: UUID) {
        guard let waiting, waiting.id == id, event.timestamp >= waiting.armedAt else { return }
        guard clock.now < waiting.deadline, Self.isFrontmost(waiting.target.pid),
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              let mouse = event.cgEvent, mouse.getIntegerValueField(.eventSourceUserData) == waiting.marker,
              hypot(mouse.location.x - waiting.point.x, mouse.location.y - waiting.point.y) <= 1,
              let windows = Self.visibleWindows(), Self.hitsTarget(waiting.point, target: waiting.target, windows: windows) else {
            complete(false)
            return
        }
        let number = mouse.getIntegerValueField(.mouseEventNumber)
        if event.type == .leftMouseDown {
            guard mouseNumber == nil else {
                complete(false)
                return
            }
            mouseNumber = number
        } else {
            complete(mouseNumber == number && Self.isFrontmost(waiting.target.pid))
        }
    }

    private func complete(_ accepted: Bool) {
        let onComplete = waiting?.onComplete
        cancel()
        onComplete?(accepted)
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func uniqueTarget(in windows: [Window], pid: pid_t, frame: CGRect) -> Window? {
        let candidates = windows.filter {
            $0.pid == pid && $0.layer == 0 &&
                abs($0.frame.minX - frame.minX) <= 1 && abs($0.frame.minY - frame.minY) <= 1 &&
                abs($0.frame.maxX - frame.maxX) <= 1 && abs($0.frame.maxY - frame.maxY) <= 1
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func matchesHitWindow(_ number: Int, target: Window, windows: [Window]) -> Bool {
        number == Int(target.id) && windows.contains {
            $0.id == target.id && $0.pid == target.pid && $0.layer == 0 && $0.frame == target.frame
        }
    }

    private static func hitsTarget(_ point: CGPoint, target: Window, windows: [Window]) -> Bool {
        guard let desktopTop = NSScreen.screens.first?.frame.maxY else { return false }
        // An overlay's bounding box can cover the point without receiving its mouse event.
        let screenPoint = CGPoint(x: point.x, y: desktopTop - point.y)
        let hit = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return matchesHitWindow(hit, target: target, windows: windows)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite &&
            rect.size.width > 0 && rect.size.height > 0
    }

    private static func visibleWindows() -> [Window]? {
        guard let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? CGWindowID, id != kCGNullWindowID,
                  let pid = item[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = item[kCGWindowLayer as String] as? Int, layer >= 0,
                  let alpha = item[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), valid(frame) else { return nil }
            return Window(id: id, pid: pid, layer: layer, frame: frame)
        }
    }

    private struct Window {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let frame: CGRect
    }

    private struct Waiting {
        let id: UUID
        let target: Window
        let point: CGPoint
        let marker: Int64
        let deadline: ContinuousClock.Instant
        let armedAt: TimeInterval
        let onComplete: (Bool) -> Void
    }
}

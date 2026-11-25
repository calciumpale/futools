import AppKit
import CoreGraphics

/// Defers the primary click until we know whether it is a click or a voice press.
@MainActor
final class PaletteVoicePress {
    private struct Press {
        let down: CGEvent
        var isHolding = false
    }

    private static let holdDuration: TimeInterval = 0.28
    private static let dragTolerance: CGFloat = 6
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var press: Press?
    private var timer: Timer?
    private var generation = 0

    var canBegin: ((CGPoint) -> Bool)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?

    func start() -> Bool {
        stop()
        guard PasteService.hasPermission else { return false }
        let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let press = Unmanaged<PaletteVoicePress>.fromOpaque(context).takeUnretainedValue()
                // The tap is installed on the main run loop.
                return MainActor.assumeIsolated {
                    let consume = press.receive(type, event: event) { $0.tapPostEvent(proxy) }
                    return consume ? nil : Unmanaged.passUnretained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        generation += 1
        _ = clearPress()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func receive(_ type: CGEventType, event: CGEvent, replayDown: (CGEvent) -> Void) -> Bool {
        switch type {
        case .leftMouseDown:
            guard press == nil else { return true }
            guard event.flags.intersection(Self.modifiers).isEmpty,
                  canBegin?(event.location) == true, let down = event.copy() else { return false }
            press = Press(down: down)
            let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginHold() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            return true

        case .leftMouseDragged:
            guard let press else { return false }
            if press.isHolding { return true }
            let point = event.location
            let origin = press.down.location
            if abs(point.x - origin.x) > Self.dragTolerance || abs(point.y - origin.y) > Self.dragTolerance {
                _ = clearPress()
                replayDown(press.down)
                return false
            }
            return true

        case .leftMouseUp:
            guard let press = clearPress() else { return false }
            guard press.isHolding else {
                replayDown(press.down)
                return false
            }
            let generation = self.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onEnd?()
            }
            return true

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let interrupted = clearPress()?.isHolding == true
            let generation = self.generation
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if interrupted {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.onCancel?()
                }
            }
            return false

        default:
            return false
        }
    }

    private func beginHold() {
        timer = nil
        guard let press, canBegin?(press.down.location) == true else { return }
        self.press?.isHolding = true
        onBegin?()
    }

    private func clearPress() -> Press? {
        timer?.invalidate()
        timer = nil
        let previous = press
        press = nil
        return previous
    }
}

import AppKit
import QuartzCore
import SwiftUI

enum DockMotion {
    static let feedbackDuration: TimeInterval = 0.12
    static let revealDuration: TimeInterval = 0.16
    static let exitDuration: TimeInterval = 0.10
    static let pageDuration: TimeInterval = 0.18
    private static let curve = (0.20, 0.78, 0.30, 1.0)

    private static func settle(_ duration: TimeInterval) -> Animation {
        .timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)
    }

    static var nativeTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
    }

    static func feedback(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : settle(feedbackDuration)
    }

    static func transition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : settle(revealDuration)
    }

    static func page(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : settle(pageDuration)
    }

    static func pageReveal(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        // A departing editor must leave immediately so only the new page can receive input.
        return .asymmetric(insertion: .opacity, removal: .identity)
    }

    static func reveal(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity
    }
}

/// Geometry and keyboard handoff remain synchronous. Only passive departure can linger visually.
@MainActor
enum DockWindowMotion {
    private struct Exit {
        let task: Task<Void, Never>
        let ignoresMouseEvents: Bool
    }

    private static var exits: [ObjectIdentifier: Exit] = [:]

    static func present(_ window: NSWindow, order: () -> Void) {
        let reversing = cancelExit(for: window)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setOpacity(1, on: window, duration: 0)
            order()
            return
        }
        if !window.isVisible { setOpacity(0.84, on: window, duration: 0) }
        order()
        if reversing || window.alphaValue < 1 { setOpacity(1, on: window, duration: DockMotion.revealDuration) }
    }

    static func hide(_ window: NSWindow) {
        _ = cancelExit(for: window)
        window.orderOut(nil)
        setOpacity(1, on: window, duration: 0)
    }

    static func close(_ window: NSWindow, onClose: @escaping () -> Void = {}) {
        guard window.isVisible, !window.isKeyWindow, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hide(window)
            onClose()
            return
        }
        let identity = ObjectIdentifier(window)
        guard exits[identity] == nil else { return }
        let ignored = window.ignoresMouseEvents
        window.ignoresMouseEvents = true
        let duration = fadePassiveWindow(window)
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            hide(window)
            onClose()
        }
        exits[identity] = Exit(task: task, ignoresMouseEvents: ignored)
    }

    private static func cancelExit(for window: NSWindow) -> Bool {
        guard let exit = exits.removeValue(forKey: ObjectIdentifier(window)) else { return false }
        exit.task.cancel()
        window.ignoresMouseEvents = exit.ignoresMouseEvents
        return true
    }

    static func fadePassiveWindow(_ window: NSWindow) -> TimeInterval {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : DockMotion.exitDuration
        setOpacity(0, on: window, duration: duration)
        return duration
    }

    private static func setOpacity(_ opacity: CGFloat, on window: NSWindow, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = DockMotion.nativeTiming
            window.animator().alphaValue = opacity
        }
    }
}

struct DockActivityGlyph: View {
    let isBusy: Bool
    var idleSymbol: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isBusy {
                Group {
                    if reduceMotion {
                        Image(systemName: "hourglass")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            } else if let idleSymbol {
                Image(systemName: idleSymbol)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .frame(width: 14, height: 14)
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isBusy)
        .accessibilityHidden(true)
    }
}

struct DockPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

import AppKit
import QuartzCore
import SwiftUI

enum DockMotion {
    static let feedbackDuration: TimeInterval = 0.10
    static let revealDuration: TimeInterval = 0.16
    static let exitDuration: TimeInterval = 0.10

    private static func settle(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.20, 0.80, 0.30, 1.0, duration: duration)
    }

    static func feedback(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : settle(feedbackDuration)
    }

    static func transition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : settle(revealDuration)
    }

    static func reveal(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity
    }
}

/// Window fades never own focus or geometry. Interactive windows leave the screen immediately.
@MainActor
enum DockWindowMotion {
    static func present(_ window: NSWindow, order: () -> Void) {
        if window.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setOpacity(1, on: window, duration: 0)
            order()
            return
        }
        setOpacity(0.76, on: window, duration: 0)
        order()
        setOpacity(1, on: window, duration: DockMotion.revealDuration)
    }

    static func hide(_ window: NSWindow) {
        window.orderOut(nil)
        setOpacity(1, on: window, duration: 0)
    }

    static func fadePassiveWindow(_ window: NSWindow) -> TimeInterval {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : DockMotion.exitDuration
        setOpacity(0, on: window, duration: duration)
        return duration
    }

    private static func setOpacity(_ opacity: CGFloat, on window: NSWindow, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.80, 0.30, 1)
            window.animator().alphaValue = opacity
        }
    }
}

struct DockActivityGlyph: View {
    let isBusy: Bool
    var idleSymbol: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
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
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

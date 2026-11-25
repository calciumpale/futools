import CoreGraphics

enum CopilotDockLayout {
    enum Side: String, CaseIterable, Sendable {
        case right, left

        var opposite: Side { self == .right ? .left : .right }

        var toggleSymbol: String { self == .right ? "sidebar.left" : "sidebar.right" }

        var toggleHelp: String { self == .right ? "切换到左侧吸附" : "切换到右侧吸附" }
    }

    static let preferredWidth: CGFloat = 360
    static let minimumWidth: CGFloat = 300
    private static let gap: CGFloat = 8

    static func panel(beside window: CGRect, visibleFrames: [CGRect], preferredSide: Side = .right) -> CGRect? {
        placement(beside: window, visibleFrames: visibleFrames, preferredSide: preferredSide)?.frame
    }

    static func placement(
        beside window: CGRect,
        visibleFrames: [CGRect],
        preferredSide: Side = .right,
        allowFallback: Bool = true
    ) -> (frame: CGRect, side: Side)? {
        let sides: [Side] = allowFallback ? [preferredSide, preferredSide.opposite] : [preferredSide]
        let sortedScreens = visibleFrames.sorted { area($0.intersection(window)) > area($1.intersection(window)) }
        for side in sides {
            for screen in sortedScreens {
                guard window.minY < screen.maxY, window.maxY > screen.minY else { continue }
                let height = min(max(window.height, 480), 840, screen.height)
                guard height >= 380 else { continue }
                let y = max(screen.minY, min(window.maxY, screen.maxY) - height)

                switch side {
                case .right:
                    let x = max(window.maxX + gap, screen.minX)
                    let width = min(preferredWidth, screen.maxX - x)
                    guard width >= minimumWidth, screen.minX <= window.maxX + gap + 24 else { continue }
                    return (CGRect(x: x, y: y, width: width, height: height), .right)
                case .left:
                    let availableRightEdge = min(window.minX - gap, screen.maxX)
                    let width = min(preferredWidth, availableRightEdge - screen.minX)
                    guard width >= minimumWidth, screen.maxX >= window.minX - gap - 24 else { continue }
                    let x = availableRightEdge - width
                    return (CGRect(x: x, y: y, width: width, height: height), .left)
                }
            }
        }
        return nil
    }

    static func resizedWindow(_ window: CGRect, visibleFrames: [CGRect], preferredSide: Side = .right) -> CGRect? {
        guard let screen = visibleFrames.max(by: { area($0.intersection(window)) < area($1.intersection(window)) }),
              screen.intersects(window) else { return nil }
        let room = screen.width - preferredWidth - gap
        guard room >= 480 else { return nil }
        let width = min(room, window.width)
        let x: CGFloat
        switch preferredSide {
        case .right:
            x = max(screen.minX, min(window.minX, screen.maxX - preferredWidth - gap - width))
        case .left:
            x = min(screen.maxX - width, max(window.minX, screen.minX + preferredWidth + gap))
        }
        return CGRect(x: x, y: window.minY, width: width, height: window.height)
    }

    private static func area(_ frame: CGRect) -> CGFloat { frame.isNull ? 0 : frame.width * frame.height }
}

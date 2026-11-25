import CoreGraphics

enum CopilotDockLayout {
    static let preferredWidth: CGFloat = 350
    static let minimumWidth: CGFloat = 300
    private static let gap: CGFloat = 8

    static func panel(beside window: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        for screen in visibleFrames.sorted(by: { area($0.intersection(window)) > area($1.intersection(window)) }) {
            let x = max(window.maxX + gap, screen.minX)
            let width = min(preferredWidth, screen.maxX - x)
            guard width >= minimumWidth, screen.minX <= window.maxX + gap + 24,
                  window.minY < screen.maxY, window.maxY > screen.minY else { continue }
            let height = min(max(window.height, 450), 740, screen.height)
            guard height >= 380 else { continue }
            let y = max(screen.minY, min(window.maxY, screen.maxY) - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    static func resizedWindow(_ window: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        guard let screen = visibleFrames.max(by: { area($0.intersection(window)) < area($1.intersection(window)) }),
              screen.intersects(window) else { return nil }
        let room = screen.width - preferredWidth - gap
        guard room >= 480 else { return nil }
        let width = min(room, window.width)
        let x = max(screen.minX, min(window.minX, screen.maxX - preferredWidth - gap - width))
        return CGRect(x: x, y: window.minY, width: width, height: window.height)
    }

    private static func area(_ frame: CGRect) -> CGFloat { frame.isNull ? 0 : frame.width * frame.height }
}

import AppKit
import Carbon.HIToolbox

@MainActor
final class WeChatRegionPicker: NSObject, NSWindowDelegate {
    struct Selection {
        let frame: NSRect
        let focusPoint: NSPoint
    }

    static let focusClearance: CGFloat = 48
    fileprivate static let minimumSize = NSSize(width: 230, height: 100)
    fileprivate static let horizontalInset: CGFloat = 12
    fileprivate static let topInset: CGFloat = 32
    fileprivate static let focusBottomInset: CGFloat = 28
    fileprivate static let focusLeftOffset: CGFloat = 24
    fileprivate static let focusBottomOffset: CGFloat = 10

    private var panel: SelectionPanel?
    private var onComplete: ((Selection?) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(in frame: NSRect, appName: String = "微信", inputTop: CGFloat? = nil,
              onComplete: @escaping (Selection?) -> Void) {
        dismiss()
        let requiredWidth = Self.minimumSize.width + 2 * Self.horizontalInset
        let requiredHeight = Self.minimumSize.height + Self.topInset + Self.focusClearance + Self.focusBottomInset
        guard frame.width >= requiredWidth, frame.height >= requiredHeight,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
            onComplete(nil)
            return
        }

        let panel = SelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.title = "框选\(appName)聊天区域"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.complete(nil) }

        let view = SelectionView(frame: NSRect(origin: .zero, size: frame.size), appName: appName, inputTop: inputTop)
        view.onSelect = { [weak self] in self?.complete($0) }
        panel.contentView = view
        panel.initialFirstResponder = view
        self.onComplete = onComplete
        self.panel = panel
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        let panel = self.panel
        self.panel = nil
        onComplete = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        complete(nil)
    }

    private func complete(_ selection: Selection?) {
        let completion = onComplete
        dismiss()
        completion?(selection)
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == kVK_Escape {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class SelectionView: NSView {
    private let inputTop: CGFloat?
    private let instructionLabel: NSAttributedString
    private let feedbackLabel: NSAttributedString
    private var instructionLayout: (size: NSSize, instruction: NSRect, feedback: NSRect)?
    private var start: NSPoint?
    private var selection = NSRect.zero
    private var showsFeedback = false
    var onSelect: ((WeChatRegionPicker.Selection) -> Void)?

    init(frame frameRect: NSRect, appName: String, inputTop: CGFloat?) {
        self.inputTop = inputTop
        let instruction = "框住消息，把选框底边拖到\(appName)能打字的区域"
        instructionLabel = Self.label(instruction)
        feedbackLabel = Self.label("请框住更多消息，底边放在\(appName)能打字的区域")
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(appName)聊天区域选择")
        setAccessibilityHelp("\(instruction)。按 Escape 取消。")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = point(in: event)
        setSelection(.zero)
        showFeedback(false)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(to: point(in: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        updateSelection(to: point(in: event))
        start = nil
        let focus = NSPoint(x: selection.minX + WeChatRegionPicker.focusLeftOffset,
                            y: selection.maxY - WeChatRegionPicker.focusBottomOffset)
        let cropBottom = cropBottom(for: focus)
        let crop = NSRect(x: selection.minX, y: selection.minY, width: selection.width, height: cropBottom - selection.minY)
        guard crop.width >= WeChatRegionPicker.minimumSize.width,
              crop.height >= WeChatRegionPicker.minimumSize.height,
              selection.contains(focus), selection.contains(crop),
              let window else {
            setSelection(.zero)
            showFeedback(true)
            return
        }
        onSelect?(.init(frame: window.convertToScreen(convert(crop, to: nil)),
                        focusPoint: window.convertPoint(toScreen: convert(focus, to: nil))))
    }

    private func cropBottom(for focus: NSPoint) -> CGFloat {
        let fallback = focus.y - WeChatRegionPicker.focusClearance
        guard let window, let inputTop, inputTop.isFinite,
              inputTop > window.frame.minY, inputTop < window.frame.maxY else { return fallback }
        let screenPoint = NSPoint(x: window.frame.minX, y: inputTop)
        let topInView = convert(window.convertPoint(fromScreen: screenPoint), from: nil).y
        guard topInView > selection.minY, topInView <= focus.y else { return fallback }
        return min(topInView, focus.y - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.27).setFill()
        shade.fill()

        if selection.width >= 2, selection.height >= 2 {
            let outline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            NSColor.systemBlue.setStroke()
            outline.stroke()
        }
        drawInstructions(in: dirtyRect)
    }

    private func updateSelection(to point: NSPoint) {
        guard let start else { return }
        let drag = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(start.x - point.x), height: abs(start.y - point.y))
        let inset = WeChatRegionPicker.horizontalInset
        let top = WeChatRegionPicker.topInset
        let bottom = WeChatRegionPicker.focusBottomInset - WeChatRegionPicker.focusBottomOffset
        let allowed = NSRect(x: bounds.minX + inset, y: bounds.minY + top,
                             width: bounds.width - 2 * inset, height: bounds.height - top - bottom)
        let clipped = drag.intersection(allowed)
        setSelection(clipped.isEmpty ? .zero : clipped)
    }

    private func setSelection(_ next: NSRect) {
        guard next != selection else { return }
        let changed = selection.isEmpty ? next : (next.isEmpty ? selection : selection.union(next))
        selection = next
        setNeedsDisplay(changed.insetBy(dx: -2, dy: -2).intersection(bounds))
    }

    private func showFeedback(_ visible: Bool) {
        guard visible != showsFeedback else { return }
        showsFeedback = visible
        let layout = headerLayout()
        setNeedsDisplay(layout.instruction.union(layout.feedback))
    }

    private func point(in event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(bounds.minX, point.x), bounds.maxX),
                       y: min(max(bounds.minY, point.y), bounds.maxY))
    }

    private static let textDrawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private static func label(_ text: String) -> NSAttributedString {
        NSAttributedString(string: "\(text)  ·  Esc 取消", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ])
    }

    private func headerLayout() -> (instruction: NSRect, feedback: NSRect) {
        if let instructionLayout, instructionLayout.size == bounds.size {
            return (instructionLayout.instruction, instructionLayout.feedback)
        }
        let available = NSSize(width: max(1, bounds.width - 44), height: bounds.height)
        func rect(for label: NSAttributedString) -> NSRect {
            let text = label.boundingRect(with: available, options: Self.textDrawingOptions).size
            let width = ceil(text.width) + 20
            return NSRect(x: floor((bounds.width - width) / 2), y: 12, width: width, height: ceil(text.height) + 14)
        }
        let layout = (instruction: rect(for: instructionLabel), feedback: rect(for: feedbackLabel))
        instructionLayout = (bounds.size, layout.instruction, layout.feedback)
        return layout
    }

    private func drawInstructions(in dirtyRect: NSRect) {
        let layout = headerLayout()
        let backdrop = showsFeedback ? layout.feedback : layout.instruction
        guard dirtyRect.intersects(backdrop) else { return }
        NSColor.black.withAlphaComponent(0.80).setFill()
        NSBezierPath(roundedRect: backdrop, xRadius: 8, yRadius: 8).fill()
        let label = showsFeedback ? feedbackLabel : instructionLabel
        label.draw(with: backdrop.insetBy(dx: 10, dy: 7), options: Self.textDrawingOptions)
    }
}

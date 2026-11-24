import AppKit
import Carbon.HIToolbox
import SwiftUI

struct PaletteTextEditor: NSViewRepresentable {
    static let searchMinimumHeight: CGFloat = 43
    private static let searchMaximumHeight: CGFloat = 150

    @Binding var text: String
    let label: String
    let fontSize: CGFloat
    let textColor: Color
    let accentColor: Color
    var placeholder = ""
    var isSearchEditor = false
    var onCommand: ((Selector) -> Bool)?
    var onOptimize: (() -> Void)?
    var onFocus: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let editor = Editor(frame: .zero)
        let unbounded = CGFloat.greatestFiniteMagnitude
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: unbounded, height: unbounded)
        editor.textContainer?.containerSize = NSSize(width: 0, height: unbounded)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 1, height: isSearchEditor ? 9 : 5)
        editor.font = .systemFont(ofSize: fontSize, weight: isSearchEditor ? .medium : .regular)
        editor.isRichText = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.setAccessibilityLabel(label)
        if !placeholder.isEmpty { editor.setAccessibilityPlaceholderValue(placeholder) }
        editor.isSearchEditor = isSearchEditor
        editor.placeholder = placeholder
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        editor.onOptimize = onOptimize
        editor.onFocus = onFocus
        let color = NSColor(textColor)
        if editor.textColor != color { editor.textColor = color }
        editor.insertionPointColor = NSColor(accentColor)
        if !editor.hasMarkedText(), editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            if isSearchEditor { scroll.invalidateIntrinsicContentSize() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard isSearchEditor, let width = proposal.width, width.isFinite,
              let editor = nsView.documentView as? NSTextView, let font = editor.font else { return nil }

        let inset = editor.textContainerInset
        let height = context.coordinator.searchHeight(
            text: text, font: font, width: width - inset.width * 2, verticalInset: inset.height * 2
        )
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaletteTextEditor
        private lazy var searchLayout = SearchTextLayout()

        init(_ parent: PaletteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText(),
                  view.string != parent.text else { return }
            parent.text = view.string
            if parent.isSearchEditor { view.enclosingScrollView?.invalidateIntrinsicContentSize() }
        }

        fileprivate func searchHeight(text: String, font: NSFont, width: CGFloat, verticalInset: CGFloat) -> CGFloat {
            guard !text.isEmpty, width > 0 else { return searchMinimumHeight }
            return searchLayout.height(for: text, font: font, width: width, verticalInset: verticalInset)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if parent.onCommand?(commandSelector) == true { return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let panel = textView.window as? PaletteWindow {
                panel.cancelOperation(nil)
                return true
            }
            return false
        }
    }

    private final class SearchTextLayout {
        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer(size: .zero)
        private var measuredFont: NSFont?

        init() {
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
        }

        func height(for text: String, font: NSFont, width: CGFloat, verticalInset: CGFloat) -> CGFloat {
            if measuredFont != font || storage.string != text {
                storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                measuredFont = font
            }

            // Reserve one additional line to measure a trailing return at the viewport boundary.
            let size = NSSize(width: width, height: searchMaximumHeight + layout.defaultLineHeight(for: font))
            if container.containerSize != size { container.containerSize = size }
            layout.ensureLayout(for: container)

            let glyphs = layout.glyphRange(for: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            if NSMaxRange(characters) < storage.length { return searchMaximumHeight }

            var height = layout.usedRect(for: container).maxY
            if layout.extraLineFragmentTextContainer === container {
                height = max(height, layout.extraLineFragmentRect.maxY)
            }
            return min(searchMaximumHeight, max(searchMinimumHeight, ceil(height + verticalInset)))
        }
    }

    private final class EditorScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let editor = documentView as? NSTextView else { return }
            let viewport = contentSize
            let resized = editor.minSize.height != viewport.height || editor.frame.width != viewport.width
            if editor.minSize.height != viewport.height { editor.minSize = NSSize(width: 0, height: viewport.height) }
            let size = NSSize(width: viewport.width, height: max(viewport.height, editor.frame.height))
            if editor.frame.size != size { editor.setFrameSize(size) }
            if resized { editor.sizeToFit() }
        }
    }

    private final class Editor: NSTextView {
        var isSearchEditor = false
        var placeholder = ""
        var onOptimize: (() -> Void)?
        var onFocus: (() -> Void)?

        override var needsPanelToBecomeKey: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard isSearchEditor, let panel = window as? PaletteWindow else { return }
            panel.searchField = self
            panel.initialFirstResponder = self
            if panel.isKeyWindow { panel.focusSearch() }
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder === self else { return }
                self.onFocus?()
            }
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText() else { return }
            let inset = textContainerInset
            (placeholder as NSString).draw(
                with: bounds.insetBy(dx: inset.width, dy: inset.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor]
            )
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, handleEditingShortcut(event) { return true }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if !handleEditingShortcut(event) { super.keyDown(with: event) }
        }

        private func handleEditingShortcut(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers.contains(.command) else { return false }
            if modifiers == .command, event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter,
               let onOptimize, !hasMarkedText() {
                if !event.isARepeat { onOptimize() }
                return true
            }
            // The target app can own the menu bar while this panel accepts key input.
            let character = event.characters(byApplyingModifiers: .command) ?? event.charactersIgnoringModifiers
            switch (modifiers, character?.lowercased()) {
            case (.command, "a"): selectAll(nil)
            case (.command, "c"): copy(nil)
            case (.command, "v"): paste(nil)
            case (.command, "x"): cut(nil)
            case (.command, "z"): undoManager?.undo()
            case ([.command, .shift], "z"): undoManager?.redo()
            default: return false
            }
            return true
        }
    }
}

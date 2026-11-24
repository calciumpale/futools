import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class CompactPromptPanel: NSObject, NSWindowDelegate {
    var onInsert: ((String, NSRunningApplication, @escaping @MainActor () -> Bool) async -> PasteOutcome)?
    var onTargetLost: (() -> Void)?
    var mayPresent: (() -> Bool)?
    var isEnabled: Bool { target != nil }
    var isVisible: Bool { panel?.isVisible == true }
    private(set) var lacksSpaceAbove = false

    private let optimizer: PromptOptimizer
    private let voice = VoiceInputController()
    private let voicePress = PaletteVoicePress()
    private var panel: PaletteWindow?
    private var target: Target?
    private var sessionID = UUID()
    private var tracking: Task<Void, Never>?
    private var targetObservation: AXObserver?
    private var workspaceObservation: AnyCancellable?
    private var targetUpdateQueued = false
    private var delivery: Task<Void, Never>?
    private var resultSubscription: AnyCancellable?
    private var revealAfter: ContinuousClock.Instant?
    private var yieldingToTarget = false
    private var targetHasFocus = false
    private var voicePressAvailable: Bool?

    init(optimizer: PromptOptimizer) {
        self.optimizer = optimizer
        super.init()
        resultSubscription = optimizer.$hasResult.removeDuplicates().sink { [weak self] ready in
            guard ready else { return }
            // @Published sends before the modeled result state is fully updated.
            DispatchQueue.main.async { [weak self] in self?.deliverResult() }
        }
        voicePress.canBegin = { [weak self] in self?.canStartVoice == true }
        voicePress.onBegin = { [weak self] in self?.beginVoice() }
        voicePress.onEnd = { [weak self] in self?.voice.finish() }
        voicePress.onCancel = { [weak self] in self?.cancelVoice() }
    }

    deinit {
        tracking?.cancel()
        delivery?.cancel()
        if let targetObservation { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(targetObservation)) }
    }

    @discardableResult
    func show(target application: NSRunningApplication) -> Bool {
        dismiss()
        lacksSpaceAbove = false
        guard let target = Target.capture(application), let anchor = target.anchorFrame() else { return false }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard screens.contains(where: { $0.intersects(anchor) }) else { return false }
        guard let frame = CompactPromptGeometry.panel(
            above: anchor, height: CompactPromptView.baseHeight, visibleFrames: screens
        ) else {
            lacksSpaceAbove = true
            return false
        }

        self.target = target
        targetHasFocus = true
        startVoicePress()
        let panel = self.panel ?? makePanel(frame: frame)
        self.panel = panel
        panel.setFrame(frame, display: false)
        DockWindowMotion.present(panel) { panel.makeKeyAndOrderFront(nil) }
        panel.focusSearch()

        observeTarget(target)
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard let self else { return }
                self.trackTarget()
            }
        }
        return true
    }

    func dismiss() {
        sessionID = UUID()
        target = nil
        tracking?.cancel()
        tracking = nil
        if let targetObservation { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(targetObservation)) }
        targetObservation = nil
        workspaceObservation = nil
        targetUpdateQueued = false
        delivery?.cancel()
        delivery = nil
        yieldingToTarget = false
        revealAfter = nil
        voice.cancel()
        hideWindow()
        optimizer.reset()
    }

    func suspendPresentation() {
        guard isEnabled else { return }
        optimizer.cancel()
        cancelVoice()
        hideWindow()
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.pendingEnter = nil
        cancelVoice()
    }

    private func observeTarget(_ target: Target) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservation = Publishers.MergeMany([
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didTerminateApplicationNotification
        ].map { workspace.publisher(for: $0) }).sink { [weak self] _ in
            DispatchQueue.main.async { self?.queueTargetUpdate() }
        }

        var observer: AXObserver?
        let result = AXObserverCreate(target.application.processIdentifier, { _, _, _, context in
            guard let context, Thread.isMainThread else { return }
            let owner = Unmanaged<CompactPromptPanel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.queueTargetUpdate() }
        }, &observer)
        guard result == .success, let observer else { return }
        target.registerGeometryNotifications(observer, context: Unmanaged.passUnretained(self).toOpaque())
        targetObservation = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func queueTargetUpdate() {
        guard isEnabled, !targetUpdateQueued else { return }
        targetUpdateQueued = true
        let session = sessionID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == session else { return }
            self.targetUpdateQueued = false
            self.trackTarget()
        }
    }

    private func makePanel(frame: NSRect) -> PaletteWindow {
        let panel = PaletteWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.title = "futools 精简面板"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.releaseKeyboardFocus() }
        panel.onConfirm = { [weak self] in self?.optimize() }
        let host = NSHostingView(rootView: CompactPromptView(
            optimizer: optimizer, voice: voice, canPressAnywhere: voicePressAvailable == true,
            optimize: { [weak self] in self?.optimize() },
            optimizeFromKeyboard: { [weak self] in self?.optimizeFromKeyboard() },
            onBeginVoice: { [weak self] in self?.beginVoice() },
            onEndVoice: { [weak self] in self?.voice.finish() },
            onCancelVoice: { [weak self] in self?.cancelVoice() }
        ))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func startVoicePress() {
        guard voicePressAvailable == nil else { return }
        voicePressAvailable = voicePress.start()
    }

    private func hideWindow() {
        targetHasFocus = false
        voicePress.stop()
        voicePressAvailable = nil
        panel?.pendingEnter = nil
        if let panel, panel.isVisible { DockWindowMotion.hide(panel) }
    }

    private func releaseKeyboardFocus() {
        cancelVoice()
        optimizer.cancel()
        revealAfter = ContinuousClock().now.advanced(by: .milliseconds(35))
        hideWindow()
    }

    private func trackTarget() {
        guard let target, let panel, !yieldingToTarget else { return }
        if let revealAfter, ContinuousClock().now < revealAfter { return }
        revealAfter = nil
        guard mayPresent?() != false, target.isCurrentWindow,
              let anchor = target.anchorFrame() else {
            if panel.isVisible { suspendPresentation() }
            return
        }

        let screens = NSScreen.screens.map(\.visibleFrame)
        let height = CompactPromptView.panelHeight(optimizer: optimizer, voice: voice)
        guard let frame = CompactPromptGeometry.panel(above: anchor, height: height, visibleFrames: screens)
            ?? CompactPromptGeometry.panel(above: anchor, height: CompactPromptView.baseHeight, visibleFrames: screens) else {
            if panel.isVisible { suspendPresentation() }
            return
        }

        targetHasFocus = !panel.isKeyWindow && target.canInsert()
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        startVoicePress()
    }

    private var canStartVoice: Bool {
        isVisible && mayPresent?() != false && target?.isFrontmost == true &&
            (panel?.isKeyWindow == true || targetHasFocus) && !optimizer.isOptimizing &&
            delivery == nil && voice.phase == .idle
    }

    private func beginVoice() {
        guard canStartVoice, let panel, let target else { return }
        if !panel.isKeyWindow {
            guard target.canInsert() else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.focusSearch()
        }
        panel.pendingEnter = nil
        voice.begin { [weak self] text in self?.insertTranscript(text) }
    }

    private func cancelVoice() {
        if voice.phase != .requestingPermission { voice.cancel() }
    }

    private func insertTranscript(_ text: String) {
        guard isVisible, let panel, panel.isKeyWindow else { return }
        panel.focusSearch()
        guard let editor = panel.searchField else {
            optimizer.draft += text
            return
        }
        if editor.hasMarkedText() { editor.unmarkText() }
        editor.insertText(text, replacementRange: editor.selectedRange())
        optimizer.draft = editor.string
    }

    private func optimizeFromKeyboard() {
        guard let keyDown = NSApp.currentEvent, keyDown.type == .keyDown else { return }
        panel?.pendingEnter = keyDown.keyCode
    }

    private func optimize() {
        guard let target, isVisible, !optimizer.isOptimizing, delivery == nil, voice.phase == .idle else { return }
        guard target.isCurrentWindow, !target.focusedDifferentField, target.fieldFrame() != nil else {
            onTargetLost?()
            return
        }
        optimizer.optimize()
    }

    private func deliverResult() {
        guard let target, optimizer.hasResult, isEnabled, delivery == nil, let onInsert else { return }
        let result = optimizer.result
        let draft = optimizer.draft
        let session = sessionID
        optimizer.clearResult()
        if panel?.isKeyWindow == true {
            yieldingToTarget = true
            hideWindow()
        }

        delivery = Task { [weak self] in
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard let self, self.sessionID == session, self.mayPresent?() != false, target.isCurrentWindow else { break }
                if target.canInsert() {
                    self.yieldingToTarget = false
                    self.trackTarget()
                    let outcome = await onInsert(result, target.application) { [weak self] in
                        guard let self, self.sessionID == session, self.mayPresent?() != false else { return false }
                        return !Task.isCancelled && target.canInsert()
                    }
                    guard !Task.isCancelled, self.sessionID == session else { return }
                    if outcome == .pasted, self.optimizer.draft == draft { self.optimizer.reset() }
                    self.delivery = nil
                    return
                }
                if target.focusedDifferentField { break }
            }
            guard !Task.isCancelled, let self, self.sessionID == session else { return }
            self.delivery = nil
            self.yieldingToTarget = false
            self.trackTarget()
            self.onTargetLost?()
        }
    }

    @MainActor
    private struct Target {
        let application: NSRunningApplication
        private let accessibilityApp: AXUIElement
        private let field: AXUIElement
        private let window: AXUIElement
        private let composer: AXUIElement?

        private var pid: pid_t { application.processIdentifier }

        static func capture(_ application: NSRunningApplication) -> Target? {
            let pid = application.processIdentifier
            guard !application.isTerminated, pid != ProcessInfo.processInfo.processIdentifier,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            let accessibility = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(accessibility, 0.15)
            guard let field = element(accessibility, kAXFocusedUIElementAttribute), belongs(field, to: pid) else { return nil }
            AXUIElementSetMessagingTimeout(field, 0.15)
            guard isEditable(field), let fieldBounds = frame(of: field),
                  let window = focusedWindow(for: field, in: accessibility), belongs(window, to: pid) else { return nil }
            AXUIElementSetMessagingTimeout(window, 0.15)
            let composer = composerGroup(around: field, bounds: fieldBounds, in: window)
            return Target(application: application, accessibilityApp: accessibility, field: field, window: window, composer: composer)
        }

        var isFrontmost: Bool {
            !application.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }

        func registerGeometryNotifications(_ observer: AXObserver, context: UnsafeMutableRawPointer) {
            for notification in [kAXMovedNotification, kAXResizedNotification,
                                 kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverAddNotification(observer, window, notification as CFString, context)
            }
            AXObserverAddNotification(observer, accessibilityApp, kAXFocusedWindowChangedNotification as CFString, context)
            AXObserverAddNotification(observer, accessibilityApp, kAXFocusedUIElementChangedNotification as CFString, context)
            AXObserverAddNotification(observer, composer ?? field, kAXLayoutChangedNotification as CFString, context)
        }

        var isCurrentWindow: Bool {
            guard isFrontmost else { return false }
            guard let focusedWindow = Self.element(accessibilityApp, kAXFocusedWindowAttribute) else { return true }
            return CFEqual(focusedWindow, window)
        }

        var focusedDifferentField: Bool {
            if let focused = Self.element(accessibilityApp, kAXFocusedUIElementAttribute), !CFEqual(focused, field) { return true }
            if let focusedWindow = Self.element(accessibilityApp, kAXFocusedWindowAttribute), !CFEqual(focusedWindow, window) { return true }
            return false
        }

        func canInsert() -> Bool {
            guard isFrontmost, Self.isEditable(field),
                  let currentWindow = Self.element(accessibilityApp, kAXFocusedWindowAttribute) ?? Self.element(field, kAXWindowAttribute),
                  CFEqual(currentWindow, window),
                  let current = Self.element(accessibilityApp, kAXFocusedUIElementAttribute),
                  Self.belongs(current, to: pid), CFEqual(current, field) else { return false }
            return isFrontmost
        }

        func fieldFrame() -> NSRect? {
            guard Self.value(window, kAXMinimizedAttribute) as? Bool != true else { return nil }
            return Self.frame(of: field)
        }

        func anchorFrame() -> NSRect? {
            guard let fieldBounds = fieldFrame() else { return nil }
            guard let composer else { return fieldBounds }
            if let bounds = Self.frame(of: composer), CompactPromptGeometry.wraps(bounds, around: fieldBounds) { return bounds }
            return Self.composerGroup(around: field, bounds: fieldBounds, in: window).flatMap { Self.frame(of: $0) }
        }

        private static func composerGroup(around field: AXUIElement, bounds: NSRect, in window: AXUIElement) -> AXUIElement? {
            var branch = field
            for _ in 0..<5 {
                guard let parent = element(branch, kAXParentAttribute), !CFEqual(parent, branch), !CFEqual(parent, window) else { break }
                AXUIElementSetMessagingTimeout(parent, 0.15)
                guard let role = value(parent, kAXRoleAttribute) as? String,
                      ![kAXApplicationRole, kAXWindowRole, "AXWebArea", kAXSplitGroupRole].contains(role) else { break }
                if role == kAXGroupRole, let outer = frame(of: parent), CompactPromptGeometry.wraps(outer, around: bounds),
                   hasActionSibling(in: parent, excluding: branch, boundedBy: outer, outside: bounds) {
                    return parent
                }
                branch = parent
            }
            return nil
        }

        private static func hasActionSibling(in group: AXUIElement, excluding branch: AXUIElement,
                                             boundedBy outer: NSRect, outside editor: NSRect) -> Bool {
            let controls = [kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole]
            for sibling in children(of: group) where !CFEqual(sibling, branch) {
                AXUIElementSetMessagingTimeout(sibling, 0.15)
                let role = value(sibling, kAXRoleAttribute) as? String
                let candidates = role == kAXGroupRole || role == kAXToolbarRole ? children(of: sibling) : [sibling]
                for child in candidates {
                    AXUIElementSetMessagingTimeout(child, 0.15)
                    guard let role = value(child, kAXRoleAttribute) as? String, controls.contains(role),
                          let frame = frame(of: child) else { continue }
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    if outer.contains(center), !editor.contains(center) { return true }
                }
            }
            return false
        }

        private static func children(of group: AXUIElement) -> [AXUIElement] {
            var result: CFArray?
            guard AXUIElementCopyAttributeValues(group, kAXChildrenAttribute as CFString, 0, 12, &result) == .success else { return [] }
            return result as? [AXUIElement] ?? []
        }

        private static func frame(of element: AXUIElement) -> NSRect? {
            guard let positionValue = Self.value(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
                  let sizeValue = Self.value(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
                  let desktopTop = NSScreen.screens.first?.frame.maxY else { return nil }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                  origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return NSRect(x: origin.x, y: desktopTop - origin.y - size.height, width: size.width, height: size.height)
        }

        private static func focusedWindow(for field: AXUIElement, in app: AXUIElement) -> AXUIElement? {
            element(field, kAXWindowAttribute) ?? element(app, kAXFocusedWindowAttribute)
        }

        private static func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success && owner == pid
        }

        private static func isEditable(_ field: AXUIElement) -> Bool {
            guard value(field, kAXEnabledAttribute) as? Bool != false,
                  value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
            if let editable = value(field, "AXEditable") as? Bool { return editable }
            guard let role = value(field, kAXRoleAttribute) as? String,
                  [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) else { return false }
            return isSettable(field, kAXValueAttribute) || isSettable(field, kAXSelectedTextAttribute)
        }

        private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
        }

        private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }

        private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
    }
}

private enum CompactPromptGeometry {
    static func panel(above anchor: CGRect, height: CGFloat, visibleFrames: [CGRect]) -> CGRect? {
        guard anchor.width >= 230 else { return nil }
        let panel = CGRect(x: anchor.minX, y: anchor.maxY + 4, width: anchor.width, height: height)
        return visibleFrames.contains(where: { $0.intersects(anchor) && $0.contains(panel) }) ? panel : nil
    }

    static func wraps(_ group: CGRect, around editor: CGRect) -> Bool {
        // A composer includes the editor and its nearby controls. Large layout wrappers are unsuitable.
        let horizontalInsets: ClosedRange<CGFloat> = -1...48
        return horizontalInsets.contains(editor.minX - group.minX) && horizontalInsets.contains(group.maxX - editor.maxX) &&
            (-1...36).contains(group.maxY - editor.maxY) && (-1...92).contains(editor.minY - group.minY)
    }
}

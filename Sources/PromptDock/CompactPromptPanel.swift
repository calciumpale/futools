import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class CompactPromptPanel: NSObject, NSWindowDelegate {
    var onInsert: ((String, NSRunningApplication, @escaping @MainActor () -> Bool) async -> PasteOutcome)?
    var onInsertAttachment: ((URL, NSRunningApplication, @escaping @MainActor () -> Bool) async -> PasteOutcome)?
    var onTargetLost: (() -> Void)?
    var onConversationSelectionLost: (() -> Void)?
    var onCopilotNotice: ((String) -> Void)?
    var mayPresent: (() -> Bool)?
    var isEnabled: Bool { target != nil }
    var isVisible: Bool { panel?.isVisible == true }
    private(set) var lacksSpaceAbove = false

    private let optimizer: PromptOptimizer
    private let copilotLibrary: CopilotLibraryStore?
    private let copilotAgent: CopilotAgentModel?
    private var isSidebar: Bool { copilotLibrary != nil }
    private let voice = VoiceInputController()
    private let voicePress = PaletteVoicePress()
    private let replyControls = CompactWeChatControls()
    private let regionPicker = WeChatRegionPicker()
    private let insertConfirmation = WeChatInsertConfirmation()
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
    private var revealTask: Task<Void, Never>?
    private var feedbackSubscription: AnyCancellable?
    private var yieldingToTarget = false
    private var targetHasFocus = false
    private var conversationVoiceArea: CGRect?
    private var voicePressAvailable: Bool?
    private var conversationRegion: ConversationRegion?
    private var adjustedWindow: (target: Target, original: NSRect, applied: NSRect)?
    private var weChatScreenshot: OCRImage?
    private var weChatPastedText: String?
    private var lastCapturedTranscript: String?
    private var lastConversationSuggestion: (reply: String, intent: String)?
    private var lastReplyTarget: (transcript: String, source: DeepSeekPromptAPI.WeChatSource, message: WeChatReplySpeakers.Message)?
    private var pendingReplyRequest: ConversationRequest?
    private var pendingReplies: (replies: [String], intent: String, scope: ConversationScope)?
    private var suggestion: Task<Void, Never>?
    private var polishTask: Task<Void, Never>?
    private var draftSubscription: AnyCancellable?
    private static let weChatCountKey = "weChatReplyCount"
    private static let weChatToneKey = "weChatReplyTone"
    private static let copilotUseLibraryKey = "copilotUseLibraryInReply"
    private static let copilotDockSideKey = "copilotDockSide"

    private var currentChatContextText: String? {
        if let pasted = weChatPastedText?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
            return pasted
        }
        if let captured = lastCapturedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !captured.isEmpty {
            return captured
        }
        return nil
    }

    init(optimizer: PromptOptimizer, copilotLibrary: CopilotLibraryStore? = nil) {
        self.optimizer = optimizer
        self.copilotLibrary = copilotLibrary
        self.copilotAgent = copilotLibrary.map { CopilotAgentModel(library: $0) }
        super.init()
        replyControls.alwaysOffersPastedContext = copilotLibrary != nil
        if isSidebar {
            replyControls.useLibraryInReply = UserDefaults.standard.bool(forKey: Self.copilotUseLibraryKey)
            if let savedSide = UserDefaults.standard.string(forKey: Self.copilotDockSideKey),
               let side = CopilotDockLayout.Side(rawValue: savedSide) {
                replyControls.dockSide = side
            }
            copilotAgent?.chatContextProvider = { [weak self] in self?.currentChatContextText }
        }
        resultSubscription = optimizer.$hasResult.removeDuplicates().sink { [weak self] ready in
            guard ready else { return }
            // @Published sends before the modeled result state is fully updated.
            DispatchQueue.main.async { [weak self] in self?.deliverResult() }
        }
        voicePress.canBegin = { [weak self] point in self?.canBeginVoicePress(at: point) == true }
        voicePress.onBegin = { [weak self] in self?.beginVoice() }
        voicePress.onEnd = { [weak self] in self?.voice.finish() }
        voicePress.onCancel = { [weak self] in self?.cancelVoice() }
        replyControls.onSuggest = { [weak self] in self?.suggestReply() }
        replyControls.onInsert = { [weak self] in self?.useReply() }
        replyControls.onDirectInsertText = { [weak self] text in self?.directInsertText(text) }
        replyControls.onPolishDraft = { [weak self] in self?.polishReplyDraft() }
        let count = UserDefaults.standard.integer(forKey: Self.weChatCountKey)
        replyControls.replyCount = (1...3).contains(count) ? count : 1
        if let saved = UserDefaults.standard.string(forKey: Self.weChatToneKey),
           let tone = DeepSeekPromptAPI.WeChatTone(rawValue: saved) { replyControls.replyTone = tone }
        replyControls.onCancel = { [weak self] in
            self?.cancelSuggestion()
            self?.trackTarget()
        }
        replyControls.onChoose = { [weak self] in self?.chooseReplyOption($0) }
        replyControls.onSetReplyCount = { [weak self] value in
            guard (1...3).contains(value) else { return }
            self?.replyControls.replyCount = value
            UserDefaults.standard.set(value, forKey: Self.weChatCountKey)
        }
        replyControls.onSetReplyTone = { [weak self] tone in
            self?.replyControls.replyTone = tone
            UserDefaults.standard.set(tone.rawValue, forKey: Self.weChatToneKey)
        }
        replyControls.onSetUseLibrary = { [weak self] enabled in
            self?.replyControls.useLibraryInReply = enabled
            UserDefaults.standard.set(enabled, forKey: Self.copilotUseLibraryKey)
        }
        replyControls.onSelectRegion = { [weak self] in self?.selectRegionAgain() }
        replyControls.onPasteScreenshot = { [weak self] in self?.pasteConversationScreenshot($0) ?? false }
        replyControls.onRemoveScreenshot = { [weak self] in self?.clearConversationContext() }
        replyControls.onPasteContext = { [weak self] in self?.pasteConversationContext() }
        draftSubscription = optimizer.$draft.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self else { return }
            if self.replyControls.insertionNotice != nil { self.replyControls.insertionNotice = nil }
            if self.suggestion != nil { self.cancelSuggestion() }
            if self.polishTask != nil { self.cancelPolish() }
        }
        feedbackSubscription = Publishers.Merge3(
            voice.$phase.map { _ in () }, voice.$message.map { _ in () }, optimizer.$errorMessage.map { _ in () }
        ).sink { [weak self] in
            // Published values are visible after this run-loop turn.
            guard self?.isSidebar == false else { return }
            self?.queueTargetUpdate()
        }
    }

    deinit {
        tracking?.cancel()
        delivery?.cancel()
        suggestion?.cancel()
        polishTask?.cancel()
        revealTask?.cancel()
        if let targetObservation { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(targetObservation)) }
    }

    @discardableResult
    func show(target application: NSRunningApplication) -> Bool {
        dismiss()
        lacksSpaceAbove = false
        guard let target = Target.capture(application, includeSidebarApps: isSidebar),
              !isSidebar || target.isConversation else { return false }
        self.target = target
        replyControls.isActive = target.isConversation
        if !isSidebar, let conversation = target.conversationApp, chatRegion(for: target) == nil {
            guard let frame = target.windowFrame(), NSScreen.screens.contains(where: { $0.frame.contains(frame) }) else {
                dismiss()
                return false
            }
            replyControls.appName = conversation.name
            let session = sessionID
            let composer = conversation == .feishu ? target.verifiedComposerFrame() : nil
            regionPicker.show(in: frame, appName: conversation.name, inputTop: composer?.maxY) { [weak self] selection in
                guard let self, self.sessionID == session else { return }
                guard let selection, target.isCurrentWindow, target.windowFrame() == frame else {
                    self.dismiss()
                    return
                }
                let placement = target.calibratedSelection(selection, composer: composer)
                self.conversationRegion = ConversationRegion(window: target.window, windowFrame: frame, selection: placement)
                if !self.presentPanel(for: target) {
                    self.conversationRegion = nil
                    self.dismiss()
                    self.onConversationSelectionLost?()
                }
            }
            return true
        }
        if let conversation = target.conversationApp { replyControls.appName = conversation.name }
        if presentPanel(for: target) { return true }
        if target.isConversation { conversationRegion = nil }
        dismiss()
        return false
    }

    private func presentPanel(for target: Target) -> Bool {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let resolvedFrame: NSRect?
        if isSidebar {
            resolvedFrame = sidebarFrame(for: target, visibleFrames: screens)
        } else {
            guard let anchor = anchorFrame(for: target), screens.contains(where: { $0.intersects(anchor) }) else { return false }
            resolvedFrame = CompactPromptGeometry.panel(
                above: anchor, height: CompactPromptView.minimumHeight(weChat: replyControls), visibleFrames: screens
            )
        }
        guard let frame = resolvedFrame else {
            lacksSpaceAbove = true
            return false
        }

        if target.isConversation {
            if let window = target.windowFrame(), let desktopTop = NSScreen.screens.first?.frame.maxY {
                replyControls.captureIsRestricted = WeChatConversationCapture.isRestricted(
                    pid: target.application.processIdentifier, windowFrame: quartzFrame(window, desktopTop: desktopTop)
                )
            }
        }
        if isSidebar { replyControls.hasSelectedRegion = chatRegion(for: target) != nil }
        if !isSidebar {
            targetHasFocus = target.hasEditableField && (!target.isConversation || canFillConversation(target))
            updateConversationVoiceArea(for: target)
        }
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
        regionPicker.dismiss()
        cancelSuggestion()
        clearConversationContext()
        lastConversationSuggestion = nil
        replyControls.captureIsRestricted = false
        replyControls.hasSelectedRegion = false
        replyControls.isActive = false
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
        revealTask?.cancel()
        revealTask = nil
        voice.cancel()
        hideWindow()
        if isSidebar {
            panel?.delegate = nil
            panel = nil
            copilotAgent?.reset()
            if let adjustedWindow, adjustedWindow.target.windowFrame() == adjustedWindow.applied {
                _ = adjustedWindow.target.changeWindowFrame(to: adjustedWindow.original)
            }
            adjustedWindow = nil
        }
        optimizer.reset()
    }

    func suspendPresentation() {
        guard isEnabled else { return }
        if regionPicker.isVisible {
            dismiss()
            return
        }
        if isSidebar { copilotAgent?.cancel() }
        if replyControls.isActive {
            cancelSuggestion()
            delivery?.cancel()
            delivery = nil
            yieldingToTarget = false
            if !isSidebar {
                clearConversationContext()
                lastConversationSuggestion = nil
                optimizer.reset()
            }
        }
        optimizer.cancel()
        cancelVoice()
        hideWindow()
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.pendingEnter = nil
        cancelVoice()
        if replyControls.isActive, !isSidebar, !yieldingToTarget, replyControls.phase != .inserting {
            cancelSuggestion()
            clearConversationContext()
            lastConversationSuggestion = nil
            optimizer.reset()
        }
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
        panel.title = isSidebar ? "futools 侧边 Copilot" : "futools 精简面板"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = isSidebar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.releaseKeyboardFocus() }
        panel.onConfirm = { [weak self] in self?.optimize() }
        let root: AnyView
        if let copilotLibrary, let copilotAgent {
            root = AnyView(CopilotSidebarView(
                optimizer: optimizer,
                voice: voice,
                controls: replyControls,
                library: copilotLibrary,
                agent: copilotAgent,
                onToggleDockSide: { [weak self] in self?.toggleDockSide() },
                onClose: { [weak self] in self?.dismiss() },
                onBeginVoice: { [weak self] in self?.beginVoice() },
                onEndVoice: { [weak self] in self?.voice.finish() },
                onCancelVoice: { [weak self] in self?.cancelVoice() },
                onStageMaterial: { [weak self] in self?.stageMaterial($0) },
                onDirectInsertText: { [weak self] text in self?.directInsertText(text) },
                onStageAnswer: { [weak self] text in self?.optimizer.draft = text }
            ))
        } else {
            let reply = CompactPromptView(
                optimizer: optimizer, voice: voice,
                optimize: { [weak self] in self?.optimize() },
                optimizeFromKeyboard: { [weak self] in self?.optimizeFromKeyboard() },
                onBeginVoice: { [weak self] in self?.beginVoice() },
                onEndVoice: { [weak self] in self?.voice.finish() },
                onCancelVoice: { [weak self] in self?.cancelVoice() },
                weChat: replyControls
            )
            root = AnyView(reply)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func startVoicePress() {
        guard !isSidebar, voicePressAvailable == nil, replyControls.phase != .inserting else { return }
        voicePressAvailable = voicePress.start()
        replyControls.canPressAnywhere = voicePressAvailable == true
    }

    private func hideWindow() {
        targetHasFocus = false
        conversationVoiceArea = nil
        voicePress.stop()
        voicePressAvailable = nil
        replyControls.canPressAnywhere = false
        panel?.pendingEnter = nil
        if let panel, panel.isVisible { DockWindowMotion.hide(panel) }
    }

    private func releaseKeyboardFocus() {
        if replyControls.phase == .inserting { return }
        if [.confirming, .choosingTarget, .choosingReply].contains(replyControls.phase) {
            cancelSuggestion()
            trackTarget()
            return
        }
        if replyControls.isActive { cancelSuggestion() }
        cancelVoice()
        optimizer.cancel()
        let deadline = ContinuousClock().now.advanced(by: .milliseconds(35))
        revealAfter = deadline
        hideWindow()
        revealTask?.cancel()
        let session = sessionID
        revealTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, self.sessionID == session else { return }
            self.revealTask = nil
            self.trackTarget()
        }
    }

    private func trackTarget() {
        guard let target, let panel, !yieldingToTarget else { return }
        if isSidebar, NSApp.modalWindow != nil || panel.attachedSheet != nil { return }
        if let revealAfter, ContinuousClock().now < revealAfter { return }
        revealAfter = nil
        guard mayPresent?() != false, target.isCurrentWindow else {
            if panel.isVisible { suspendPresentation() }
            return
        }
        guard let anchor = isSidebar ? target.windowFrame() : anchorFrame(for: target) else {
            if target.isConversation {
                dismiss()
                onConversationSelectionLost?()
            } else if panel.isVisible {
                suspendPresentation()
            }
            return
        }

        let screens = NSScreen.screens.map(\.visibleFrame)
        let panelFrame: NSRect?
        if isSidebar {
            if let placed = CopilotDockLayout.placement(
                beside: anchor, visibleFrames: screens, preferredSide: replyControls.dockSide, allowFallback: true
            ) {
                panelFrame = placed.frame
                if replyControls.dockSide != placed.side {
                    replyControls.dockSide = placed.side
                }
            } else {
                panelFrame = nil
            }
            if replyControls.hasSelectedRegion, let region = conversationRegion,
               abs(region.windowSize.width - anchor.width) >= 0.5 || abs(region.windowSize.height - anchor.height) >= 0.5 {
                replyControls.hasSelectedRegion = false
                conversationRegion = nil
            }
        } else {
            let height = CompactPromptView.panelHeight(optimizer: optimizer, voice: voice, weChat: replyControls)
            panelFrame = CompactPromptGeometry.panel(above: anchor, height: height, visibleFrames: screens)
                ?? CompactPromptGeometry.panel(above: anchor, height: CompactPromptView.minimumHeight(weChat: replyControls), visibleFrames: screens)
        }
        guard let frame = panelFrame else {
            if panel.isVisible { suspendPresentation() }
            return
        }

        if frame != panel.frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { DockWindowMotion.present(panel) { panel.orderFrontRegardless() } }
        if !isSidebar {
            targetHasFocus = !panel.isKeyWindow && (!target.isConversation || canFillConversation(target)) && target.canInsert()
            updateConversationVoiceArea(for: target)
        }
        startVoicePress()
    }

    private func sidebarFrame(for target: Target, visibleFrames: [CGRect]) -> NSRect? {
        guard let window = target.windowFrame() else { return nil }
        let preferred = replyControls.dockSide
        if let direct = CopilotDockLayout.placement(
            beside: window, visibleFrames: visibleFrames, preferredSide: preferred, allowFallback: false
        ) {
            replyControls.dockSide = direct.side
            return direct.frame
        }
        if let desired = CopilotDockLayout.resizedWindow(window, visibleFrames: visibleFrames, preferredSide: preferred),
           desired != window, target.isCurrentWindow {
            let actual = target.changeWindowFrame(to: desired) ?? window
            if actual != window { adjustedWindow = (target, window, actual) }
            if let placed = CopilotDockLayout.placement(
                beside: actual, visibleFrames: visibleFrames, preferredSide: preferred, allowFallback: true
            ) {
                replyControls.dockSide = placed.side
                return placed.frame
            }
        }
        if let fallback = CopilotDockLayout.placement(
            beside: window, visibleFrames: visibleFrames, preferredSide: preferred, allowFallback: true
        ) {
            replyControls.dockSide = fallback.side
            return fallback.frame
        }
        return nil
    }

    private func toggleDockSide() {
        guard isSidebar, let target, let panel, let window = target.windowFrame() else { return }
        let nextSide = replyControls.dockSide.opposite
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let direct = CopilotDockLayout.placement(
            beside: window, visibleFrames: screens, preferredSide: nextSide, allowFallback: false
        ) {
            replyControls.dockSide = nextSide
            UserDefaults.standard.set(nextSide.rawValue, forKey: Self.copilotDockSideKey)
            panel.setFrame(direct.frame, display: true)
            return
        }
        if let desired = CopilotDockLayout.resizedWindow(window, visibleFrames: screens, preferredSide: nextSide),
           desired != window, target.isCurrentWindow {
            let baseline = adjustedWindow?.original ?? window
            let actual = target.changeWindowFrame(to: desired) ?? window
            if actual != baseline { adjustedWindow = (target, baseline, actual) }
            if let placed = CopilotDockLayout.placement(
                beside: actual, visibleFrames: screens, preferredSide: nextSide, allowFallback: false
            ) {
                replyControls.dockSide = nextSide
                UserDefaults.standard.set(nextSide.rawValue, forKey: Self.copilotDockSideKey)
                panel.setFrame(placed.frame, display: true)
                return
            }
        }
        onCopilotNotice?(nextSide == .left ? "窗口左侧空间不足，无法切换吸附方向。" : "窗口右侧空间不足，无法切换吸附方向。")
    }

    private var canStartVoice: Bool {
        isVisible && mayPresent?() != false && target?.isFrontmost == true && !optimizer.isOptimizing &&
            delivery == nil && suggestion == nil && polishTask == nil &&
            ![.confirming, .choosingTarget, .choosingReply, .inserting].contains(replyControls.phase) && voice.phase == .idle
    }

    private func updateConversationVoiceArea(for target: Target) {
        if target.isConversation, let window = target.windowFrame(), let desktopTop = NSScreen.screens.first?.frame.maxY {
            conversationVoiceArea = quartzFrame(window, desktopTop: desktopTop)
        } else {
            conversationVoiceArea = nil
        }
    }

    private func canBeginVoicePress(at point: CGPoint) -> Bool {
        guard canStartVoice else { return false }
        return panel?.isKeyWindow == true || targetHasFocus || conversationVoiceArea?.contains(point) == true
    }

    private func beginVoice() {
        guard canStartVoice, let panel, let target else { return }
        if !panel.isKeyWindow {
            guard target.isConversation ? target.isCurrentWindow : target.canInsert() else { return }
            panel.makeKeyAndOrderFront(nil)
        }
        guard panel.isKeyWindow else { return }
        panel.focusSearch()
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
        if editor.hasMarkedText() {
            editor.unmarkText()
            optimizer.draft = editor.string
        }
        guard editor.string == optimizer.draft else {
            optimizer.draft += text
            return
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
        optimizer.draft = editor.string
    }

    private func optimizeFromKeyboard() {
        guard !replyControls.isActive else { return }
        guard let keyDown = NSApp.currentEvent, keyDown.type == .keyDown else { return }
        panel?.pendingEnter = keyDown.keyCode
    }

    private func optimize() {
        guard let target, !target.isConversation, isVisible, !optimizer.isOptimizing, delivery == nil, voice.phase == .idle else { return }
        guard target.isCurrentWindow, !target.focusedDifferentField, target.fieldFrame() != nil else {
            onTargetLost?()
            return
        }
        optimizer.optimize()
    }

    func shouldRetarget(_ application: NSRunningApplication) -> Bool {
        guard let target else { return false }
        if target.application.processIdentifier != application.processIdentifier { return true }
        return target.isConversation && target.isFrontmost && !target.isCurrentWindow
    }

    private func anchorFrame(for target: Target) -> NSRect? {
        guard target.isConversation else { return target.anchorFrame() }
        guard let region = chatRegion(for: target) else { return nil }
        if target.conversationApp == .feishu, let composer = target.verifiedComposerFrame() { return composer }
        if canFillConversation(target, region: region), let anchor = target.anchorFrame() { return anchor }
        // The capture starts above the editable area marked during selection.
        return NSRect(x: region.minX, y: region.minY - 5, width: region.width, height: 1)
    }

    private func canFillConversation(_ target: Target, region: NSRect? = nil) -> Bool {
        if isSidebar {
            guard target.hasConversationEditor else { return false }
            if chatRegion(for: target) == nil { return true }
        }
        guard let region = region ?? chatRegion(for: target), let field = target.fieldFrame(),
              let window = target.windowFrame(), let point = conversationRegion?.focusPoint(in: window),
              field.contains(point) else { return false }
        let gap = region.minY - field.maxY
        return field.midX >= region.minX && field.midX <= region.maxX && (-8...120).contains(gap)
    }

    private func chatRegion(for target: Target) -> NSRect? {
        guard let conversationRegion, CFEqual(conversationRegion.window, target.window), let frame = target.windowFrame(),
              abs(conversationRegion.windowSize.width - frame.width) < 0.5,
              abs(conversationRegion.windowSize.height - frame.height) < 0.5 else { return nil }
        let region = conversationRegion.relativeSelection.offsetBy(dx: frame.minX, dy: frame.minY)
        return frame.contains(region) ? region : nil
    }

    private func selectRegionAgain(continueSuggestion: Bool = false) {
        guard let target, target.isConversation, target.isCurrentWindow, suggestion == nil, delivery == nil,
              replyControls.phase != .inserting else { return }
        if isSidebar {
            guard let window = target.windowFrame(), NSScreen.screens.contains(where: { $0.frame.contains(window) }) else {
                onCopilotNotice?("请把会话窗口完整放在一块屏幕上，再框选消息。")
                return
            }
            let session = sessionID
            cancelSuggestion()
            yieldingToTarget = true
            hideWindow()
            let composer = target.verifiedComposerFrame()
            regionPicker.show(in: window, appName: replyControls.appName, inputTop: composer?.maxY) { [weak self] selection in
                guard let self, self.sessionID == session else { return }
                self.yieldingToTarget = false
                let validSelection = target.isCurrentWindow && target.windowFrame() == window ? selection : nil
                if let validSelection {
                    self.clearConversationContext()
                    self.conversationRegion = ConversationRegion(window: target.window, windowFrame: window,
                        selection: target.calibratedSelection(validSelection, composer: composer))
                    self.replyControls.hasSelectedRegion = true
                }
                self.trackTarget()
                if continueSuggestion, validSelection != nil { self.suggestReply() }
            }
            return
        }
        conversationRegion = nil
        if !show(target: target.application) { onConversationSelectionLost?() }
    }

    private func pasteConversationScreenshot(_ board: NSPasteboard) -> Bool {
        guard replyControls.isActive, OCRImage.canRead(from: board) else { return false }
        do {
            let image = try OCRImage.read(from: board)
            cancelSuggestion()
            clearConversationContext()
            restoreReplyIntent()
            weChatScreenshot = image
            replyControls.hasScreenshot = true
            replyControls.screenshotPreview = isSidebar ? image.preview : nil
        } catch {
            cancelSuggestion()
            replyControls.phase = .failed(error.localizedDescription)
        }
        trackTarget()
        return true
    }

    private func pasteConversationContext() {
        guard isVisible, let target, target.isConversation, target.isCurrentWindow,
              suggestion == nil, voice.phase == .idle else { return }
        let pasteboard = NSPasteboard.general
        if pasteConversationScreenshot(pasteboard) { return }
        let copied = pasteboard.string(forType: .string) ?? ""
        let recent = copied.suffix(3_500)
        let text = String(recent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            replyControls.phase = .failed("请先复制聊天文字或截图，再点粘贴。")
            trackTarget()
            return
        }
        cancelSuggestion()
        clearConversationContext()
        restoreReplyIntent()
        weChatPastedText = text
        let preview = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limitNotice = recent.startIndex == copied.startIndex ? "" : "仅保留最后 3,500 字 · "
        replyControls.pastedTextPreview = limitNotice + String(preview.prefix(40)) + (preview.count > 40 ? "…" : "")
        replyControls.pastedFullText = text
        trackTarget()
    }

    private func clearConversationContext() {
        weChatScreenshot = nil
        weChatPastedText = nil
        lastCapturedTranscript = nil
        lastReplyTarget = nil
        replyControls.replyTargetPreview = nil
        replyControls.insertionNotice = nil
        replyControls.screenshotPreview = nil
        replyControls.pastedFullText = nil
        replyControls.recentSuggestions = []
        replyControls.matchedLibraryCount = 0
        if replyControls.hasScreenshot { replyControls.hasScreenshot = false }
        if replyControls.pastedTextPreview != nil { replyControls.pastedTextPreview = nil }
    }

    private func restoreReplyIntent() {
        guard let lastConversationSuggestion else { return }
        self.lastConversationSuggestion = nil
        if optimizer.draft == lastConversationSuggestion.reply { optimizer.draft = lastConversationSuggestion.intent }
    }

    private func suggestReply() {
        if suggestion != nil {
            cancelSuggestion()
            return
        }
        cancelPolish()
        guard let target, let conversation = target.conversationApp, isVisible, target.isCurrentWindow, delivery == nil, voice.phase == .idle,
              let panel, let frame = target.windowFrame(),
              let desktopTop = NSScreen.screens.first?.frame.maxY else { return }
        guard ![.choosingTarget, .choosingReply, .inserting].contains(replyControls.phase) else { return }
        let pastedScreenshot = weChatScreenshot
        let pastedText = weChatPastedText
        guard !replyControls.captureIsRestricted || pastedScreenshot != nil || pastedText != nil else { return }
        let region = chatRegion(for: target)
        if region == nil && pastedText == nil && pastedScreenshot == nil {
            if isSidebar { selectRegionAgain(continueSuggestion: true) }
            return
        }
        panel.makeKeyAndOrderFront(nil)
        panel.focusSearch()
        if !UserDefaults.standard.bool(forKey: conversation.replyConsentKey) {
            if replyControls.phase != .confirming {
                replyControls.phase = .confirming
                trackTarget()
                return
            }
            UserDefaults.standard.set(true, forKey: conversation.replyConsentKey)
        }

        let scope = ConversationScope(target: target, session: sessionID, window: frame, region: region)
        let intent: String
        if let lastConversationSuggestion, lastConversationSuggestion.reply == optimizer.draft {
            intent = lastConversationSuggestion.intent
        } else {
            intent = optimizer.draft
        }
        let source: DeepSeekPromptAPI.WeChatSource = pastedText == nil ? .screenshot : .copiedText
        let tone = replyControls.replyTone
        let count = replyControls.replyCount
        let captureWindow = quartzFrame(frame, desktopTop: desktopTop)
        let captureRegion = region.map { quartzFrame($0, desktopTop: desktopTop) }
        replyControls.phase = pastedText == nil ? .capturing : .suggesting
        suggestion = Task { [weak self] in
            do {
                guard try DeepSeekKeychain.exists() else { throw DeepSeekPromptAPI.Failure.missingKey }
                let transcript: String
                if let pastedText {
                    transcript = pastedText
                } else if let pastedScreenshot {
                    transcript = try await WeChatConversationCapture.recognize(screenshot: pastedScreenshot)
                } else if let captureRegion {
                    transcript = try await WeChatConversationCapture.recognize(
                        pid: target.application.processIdentifier, windowFrame: captureWindow, transcriptFrame: captureRegion
                    )
                } else {
                    throw DeepSeekPromptAPI.Failure.emptyConversation
                }
                try Task.checkCancellation()
                guard let self else { return }
                guard self.matchesConversationScope(scope) else {
                    if self.sessionID == scope.session { self.cancelSuggestion() }
                    return
                }
                self.lastCapturedTranscript = transcript
                self.suggestion = nil
                self.prepareReplyRequest(.init(scope: scope, transcript: transcript, intent: intent,
                                                source: source, tone: tone, count: count))
            } catch {
                guard !Task.isCancelled else { return }
                self?.showConversationFailure(error, session: scope.session)
            }
        }
        trackTarget()
    }

    private func prepareReplyRequest(_ request: ConversationRequest) {
        let speakers = request.speakers
        if let previous = lastReplyTarget, previous.transcript == request.transcript,
           previous.source == request.source {
            generateReplies(request, respondingTo: previous.message)
        } else if let counterpart = speakers.confirmedCounterpart {
            generateReplies(request, respondingTo: counterpart)
        } else {
            let choices = speakers.selectableCounterparts
            guard !choices.isEmpty else {
                replyControls.phase = .failed("请补上对方说的话，再生成回复。")
                trackTarget()
                return
            }
            pendingReplyRequest = request
            replyControls.replyTargetPreview = nil
            replyControls.choices = choices.map {
                CompactWeChatChoice(id: $0.id, text: $0.text,
                                     detail: $0.speaker == .counterpart ? "对方" : $0.positionHint)
            }
            replyControls.phase = .choosingTarget
            trackTarget()
        }
    }

    private func chooseReplyOption(_ id: Int) {
        if replyControls.phase == .choosingTarget, let request = pendingReplyRequest,
           let message = request.speakers.selectableCounterparts.first(where: { $0.id == id }),
           matchesConversationScope(request.scope) {
            pendingReplyRequest = nil
            generateReplies(request, respondingTo: message)
        } else if replyControls.phase == .choosingReply, let pending = pendingReplies,
                  pending.replies.indices.contains(id), matchesConversationScope(pending.scope) {
            putReplyInDraft(pending.replies[id], intent: pending.intent, keepRecentSuggestions: isSidebar)
        }
    }

    private func generateReplies(_ request: ConversationRequest, respondingTo message: WeChatReplySpeakers.Message) {
        lastReplyTarget = (transcript: request.transcript, source: request.source, message: message)
        replyControls.replyTargetPreview = String(message.text.prefix(60)) + (message.text.count > 60 ? "…" : "")
        replyControls.choices = []
        replyControls.phase = .suggesting

        let references: [CopilotSource]
        if isSidebar, replyControls.useLibraryInReply, let copilotLibrary {
            let lookupQuery = [message.text, request.intent]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let matches = copilotLibrary.search(lookupQuery, limit: 4)
                .filter { $0.kind == .text || $0.kind == .link }
            references = matches.map { material in
                let url = material.kind == .link ? DeepSeekPromptAPI.publicWebURL(material.body) : nil
                return CopilotSource(
                    title: material.title,
                    excerpt: String(material.body.prefix(500)),
                    url: url,
                    isLocal: true
                )
            }
        } else {
            references = []
        }
        replyControls.matchedLibraryCount = references.count

        suggestion = Task { [weak self] in
            do {
                let replies = try await DeepSeekPromptAPI.suggestWeChatReplies(
                    request.speakers.transcript(includingCounterpart: message), preference: request.intent,
                    source: request.source, replyTo: message.text, tone: request.tone, count: request.count,
                    referenceMaterials: references
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard self.matchesConversationScope(request.scope) else {
                    if self.sessionID == request.scope.session { self.cancelSuggestion() }
                    return
                }
                self.suggestion = nil
                if replies.count == 1 {
                    self.replyControls.recentSuggestions = []
                    self.putReplyInDraft(replies[0], intent: request.intent)
                } else {
                    self.pendingReplies = (replies, request.intent, request.scope)
                    if self.isSidebar { self.replyControls.recentSuggestions = replies }
                    self.replyControls.choices = replies.enumerated().map {
                        CompactWeChatChoice(id: $0.offset, text: $0.element, detail: nil)
                    }
                    self.replyControls.phase = .choosingReply
                    self.trackTarget()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.showConversationFailure(error, session: request.scope.session)
            }
        }
        trackTarget()
    }

    private func putReplyInDraft(_ reply: String, intent: String, keepRecentSuggestions: Bool = false) {
        pendingReplies = nil
        replyControls.choices = []
        if !keepRecentSuggestions { replyControls.recentSuggestions = [] }
        lastConversationSuggestion = (reply: reply, intent: intent)
        optimizer.draft = reply
        replyControls.phase = .idle
        trackTarget()
    }

    private func polishReplyDraft() {
        guard isSidebar, isVisible, delivery == nil, suggestion == nil, polishTask == nil,
              voice.phase == .idle, !replyControls.phase.isBusy else { return }
        let draft = optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        let tone = replyControls.replyTone
        let session = sessionID
        replyControls.isPolishing = true
        replyControls.insertionNotice = nil
        if case .failed = replyControls.phase { replyControls.phase = .idle }
        polishTask = Task { [weak self] in
            do {
                let polished = try await DeepSeekPromptAPI.polishReply(draft, tone: tone)
                try Task.checkCancellation()
                guard let self, self.sessionID == session else { return }
                self.polishTask = nil
                self.replyControls.isPolishing = false
                self.optimizer.draft = polished
            } catch {
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.polishTask = nil
                self.replyControls.isPolishing = false
                self.replyControls.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelPolish() {
        polishTask?.cancel()
        polishTask = nil
        if replyControls.isPolishing { replyControls.isPolishing = false }
    }

    private func directInsertText(_ text: String) {
        guard let target, target.isConversation, target.isCurrentWindow, isVisible,
              delivery == nil, suggestion == nil, polishTask == nil, voice.phase == .idle,
              replyControls.phase != .inserting else {
            onCopilotNotice?("请保持目标会话可见，等待当前操作完成后重试。")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stage(.text(trimmed), in: target)
    }

    private func showConversationFailure(_ error: Error, session: UUID) {
        guard sessionID == session else { return }
        suggestion = nil
        if WeChatConversationCapture.indicatesRestriction(error) { replyControls.captureIsRestricted = true }
        replyControls.phase = .failed(error.localizedDescription)
        trackTarget()
    }

    private func matchesConversationScope(_ scope: ConversationScope) -> Bool {
        sessionID == scope.session && scope.target.isCurrentWindow && panel?.isKeyWindow == true &&
            scope.target.windowFrame() == scope.window && chatRegion(for: scope.target) == scope.region
    }

    private func quartzFrame(_ frame: NSRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private func cancelSuggestion() {
        suggestion?.cancel()
        suggestion = nil
        cancelPolish()
        insertConfirmation.cancel()
        pendingReplyRequest = nil
        pendingReplies = nil
        replyControls.choices = []
        replyControls.phase = .idle
    }

    private func useReply() {
        guard let target, target.isConversation, target.isCurrentWindow, isVisible,
              isSidebar || chatRegion(for: target) != nil, suggestion == nil, polishTask == nil, delivery == nil,
              ![.confirming, .choosingTarget, .choosingReply, .inserting].contains(replyControls.phase),
              voice.phase == .idle else { return }
        if let editor = panel?.searchField, editor.hasMarkedText() {
            editor.unmarkText()
            optimizer.draft = editor.string
        }
        let text = optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stage(.text(text), in: target)
    }

    private func stageMaterial(_ material: CopilotMaterial) {
        guard let copilotLibrary, let target, isVisible, target.isCurrentWindow,
              delivery == nil, suggestion == nil, polishTask == nil, voice.phase == .idle, replyControls.phase != .inserting else {
            onCopilotNotice?("请保持目标会话可见，等待当前操作完成后重试。")
            return
        }
        switch material.kind {
        case .text, .link:
            stage(.text(material.body), in: target)
        case .image, .video:
            guard let file = copilotLibrary.attachmentURL(for: material) else {
                onCopilotNotice?("找不到资料附件，请重新导入。")
                return
            }
            stage(.attachment(file), in: target)
        }
    }

    private func stage(_ content: DeliveryContent, in target: Target) {
        if isSidebar, target.hasEditableField, target.focusedDifferentField {
            failConversationInsertion("当前输入框已切换，请重新打开侧边 Copilot 后操作。")
            return
        }
        replyControls.insertionNotice = nil
        replyControls.phase = .inserting
        if canFillConversation(target) && !target.focusedDifferentField {
            deliver(content, to: target)
        } else {
            focusConversationInput(content, target: target)
        }
    }

    private enum DeliveryContent {
        case text(String)
        case attachment(URL)
    }

    private func focusConversationInput(_ content: DeliveryContent, target: Target) {
        let appName = replyControls.appName
        guard mayPresent?() != false, target.isCurrentWindow,
              let window = target.windowFrame(), let region = chatRegion(for: target),
              let point = conversationRegion?.focusPoint(in: window), let desktopTop = NSScreen.screens.first?.frame.maxY else {
            failConversationInsertion(isSidebar ? "请先把光标放进\(appName)聊天输入框，或框选一次会话。"
                                      : "\(appName)会话已变化，草稿已保留。")
            return
        }
        let focusArea = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        let quartzPoint = CGPoint(x: point.x, y: desktopTop - point.y)
        guard window.contains(focusArea), !region.intersects(focusArea), target.allowsConversationClick(at: quartzPoint) else {
            failConversationInsertion("请重新框选，把选框底边放在\(appName)能打字的区域。")
            return
        }
        let focus = ConversationFocus(window: window, region: region, point: point)
        let session = sessionID
        let draft = optimizer.draft
        yieldingToTarget = true
        hideWindow()
        let started = insertConfirmation.start(pid: target.application.processIdentifier,
                                               windowFrame: quartzFrame(window, desktopTop: desktopTop),
                                               composerFrame: quartzFrame(focusArea, desktopTop: desktopTop),
                                               focusPoint: quartzPoint) { [weak self] confirmed in
            guard let self, self.sessionID == session, self.replyControls.phase == .inserting else { return }
            guard confirmed, self.mayPresent?() != false,
                  self.optimizer.draft == draft else {
                self.failConversationInsertion("无法定位\(appName)输入区，请保持原会话可见后重试。")
                return
            }
            self.deliver(content, to: target, confirmedConversationFocus: focus)
        }
        if !started { failConversationInsertion("无法定位\(appName)输入区，请保持原会话可见后重试。") }
    }

    private func failConversationInsertion(_ message: String) {
        yieldingToTarget = false
        replyControls.phase = .failed(message)
        if isSidebar { onCopilotNotice?(message) }
        trackTarget()
    }

    private func deliverResult() {
        guard let target, !target.isConversation, optimizer.hasResult, delivery == nil else { return }
        let result = optimizer.result
        optimizer.clearResult()
        deliver(.text(result), to: target)
    }

    private func deliver(_ content: DeliveryContent, to target: Target, confirmedConversationFocus: ConversationFocus? = nil) {
        guard delivery == nil else { return }
        let draft = optimizer.draft
        let session = sessionID
        if target.isConversation || panel?.isKeyWindow == true {
            yieldingToTarget = true
            hideWindow()
        }

        delivery = Task { [weak self] in
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard let self, self.sessionID == session, self.mayPresent?() != false, target.isCurrentWindow else { break }
                if self.hasPasteFocus(target, confirmedConversationFocus: confirmedConversationFocus) {
                    if !target.isConversation {
                        self.yieldingToTarget = false
                        self.trackTarget()
                    }
                    let validate: @MainActor () -> Bool = { [weak self] in
                        guard let self, self.sessionID == session, self.mayPresent?() != false else { return false }
                        return !Task.isCancelled && self.hasPasteFocus(target, confirmedConversationFocus: confirmedConversationFocus)
                    }
                    let outcome: PasteOutcome
                    switch content {
                    case .text(let text): outcome = await self.onInsert?(text, target.application, validate) ?? .failed
                    case .attachment(let file): outcome = await self.onInsertAttachment?(file, target.application, validate) ?? .failed
                    }
                    guard !Task.isCancelled, self.sessionID == session else { return }
                    self.delivery = nil
                    if target.isConversation {
                        switch outcome {
                        case .pasted:
                            self.yieldingToTarget = false
                            self.replyControls.phase = .idle
                            self.replyControls.insertionNotice = "请在\(self.replyControls.appName)输入框核对草稿后发送。"
                            if self.isSidebar { self.onCopilotNotice?("请在\(self.replyControls.appName)核对待发送内容。") }
                            self.trackTarget()
                        case .targetLostFocus where confirmedConversationFocus == nil && self.optimizer.draft == draft:
                            self.focusConversationInput(content, target: target)
                        default:
                            self.failConversationInsertion("未能填入\(self.replyControls.appName)，草稿已保留。")
                        }
                    } else if outcome == .pasted, self.optimizer.draft == draft {
                        self.optimizer.reset()
                    }
                    return
                }
                if confirmedConversationFocus == nil, target.focusedDifferentField { break }
            }
            guard !Task.isCancelled, let self, self.sessionID == session else { return }
            self.delivery = nil
            if target.isConversation {
                if confirmedConversationFocus == nil, self.optimizer.draft == draft {
                    self.focusConversationInput(content, target: target)
                } else {
                    self.failConversationInsertion("\(self.replyControls.appName)输入框失去焦点，草稿已保留。")
                }
            } else {
                self.yieldingToTarget = false
                self.trackTarget()
                self.onTargetLost?()
            }
        }
    }

    private func hasPasteFocus(_ target: Target, confirmedConversationFocus: ConversationFocus?) -> Bool {
        guard target.isConversation else { return target.canInsert() }
        guard panel?.isKeyWindow == false else { return false }
        guard let focus = confirmedConversationFocus else { return canFillConversation(target) && target.canInsert() }
        return target.isCurrentWindow && target.windowFrame() == focus.window && chatRegion(for: target) == focus.region &&
            target.acceptsConversationPaste(at: focus.point)
    }

    private struct ConversationFocus {
        let window: NSRect
        let region: NSRect
        let point: NSPoint
    }

    private struct ConversationScope {
        let target: Target
        let session: UUID
        let window: NSRect
        let region: NSRect?
    }

    private struct ConversationRequest {
        let scope: ConversationScope
        let transcript: String
        let intent: String
        let source: DeepSeekPromptAPI.WeChatSource
        let tone: DeepSeekPromptAPI.WeChatTone
        let count: Int
        let speakers: WeChatReplySpeakers

        @MainActor init(scope: ConversationScope, transcript: String, intent: String, source: DeepSeekPromptAPI.WeChatSource,
             tone: DeepSeekPromptAPI.WeChatTone, count: Int) {
            self.scope = scope
            self.transcript = transcript
            self.intent = intent
            self.source = source
            self.tone = tone
            self.count = count
            speakers = WeChatReplySpeakers(transcript, fromScreenshot: source == .screenshot,
                                           inferSidesFromScreenshot: scope.target.conversationApp == .weChat)
        }
    }

    @MainActor
    private struct Target {
        let application: NSRunningApplication
        private let accessibilityApp: AXUIElement
        private let field: AXUIElement?
        let window: AXUIElement
        private let composer: AXUIElement?
        private let includeSidebarApps: Bool

        private var pid: pid_t { application.processIdentifier }
        var conversationApp: ConversationApp? {
            guard let app = ConversationApp(bundleIdentifier: application.bundleIdentifier),
                  includeSidebarApps || app.supportsCompactReply else { return nil }
            return app
        }
        var isConversation: Bool { conversationApp != nil }
        var hasEditableField: Bool { field != nil }
        var hasConversationEditor: Bool {
            guard let field, Self.conversationInputKind(field) == .editor else { return false }
            return composer != nil || Self.value(field, kAXRoleAttribute) as? String == kAXTextAreaRole
        }

        static func capture(_ application: NSRunningApplication, includeSidebarApps: Bool = false) -> Target? {
            let pid = application.processIdentifier
            guard !application.isTerminated, pid != ProcessInfo.processInfo.processIdentifier,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            let accessibility = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(accessibility, 0.15)
            if let field = element(accessibility, kAXFocusedUIElementAttribute), belongs(field, to: pid) {
                AXUIElementSetMessagingTimeout(field, 0.15)
                if isEditable(field), let bounds = frame(of: field),
                   let window = focusedWindow(for: field, in: accessibility), belongs(window, to: pid) {
                    AXUIElementSetMessagingTimeout(window, 0.15)
                    let composer = composerGroup(around: field, bounds: bounds, in: window,
                                                 conversation: ConversationApp(bundleIdentifier: application.bundleIdentifier))
                    return Target(application: application, accessibilityApp: accessibility, field: field, window: window,
                                  composer: composer, includeSidebarApps: includeSidebarApps)
                }
            }
            guard let conversation = ConversationApp(bundleIdentifier: application.bundleIdentifier), includeSidebarApps || conversation.supportsCompactReply,
                  let window = currentWindow(in: accessibility), belongs(window, to: pid),
                  value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
            AXUIElementSetMessagingTimeout(window, 0.15)
            return Target(application: application, accessibilityApp: accessibility, field: nil, window: window,
                          composer: nil, includeSidebarApps: includeSidebarApps)
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
            if let layout = composer ?? field {
                AXObserverAddNotification(observer, layout, kAXLayoutChangedNotification as CFString, context)
            }
        }

        var isCurrentWindow: Bool {
            guard isFrontmost else { return false }
            if isConversation {
                guard let focused = Self.currentWindow(in: accessibilityApp) else { return false }
                return CFEqual(focused, window)
            }
            guard let focusedWindow = Self.element(accessibilityApp, kAXFocusedWindowAttribute) else { return true }
            return CFEqual(focusedWindow, window)
        }

        var focusedDifferentField: Bool {
            if let field, let focused = Self.element(accessibilityApp, kAXFocusedUIElementAttribute), !CFEqual(focused, field) { return true }
            if let focusedWindow = Self.element(accessibilityApp, kAXFocusedWindowAttribute), !CFEqual(focusedWindow, window) { return true }
            return false
        }

        func canInsert() -> Bool {
            guard let field, isFrontmost, Self.isEditable(field),
                  let currentWindow = Self.element(accessibilityApp, kAXFocusedWindowAttribute) ?? Self.element(field, kAXWindowAttribute),
                  CFEqual(currentWindow, window),
                  let current = Self.element(accessibilityApp, kAXFocusedUIElementAttribute),
                  Self.belongs(current, to: pid), CFEqual(current, field) else { return false }
            return isFrontmost
        }

        func allowsConversationClick(at point: CGPoint) -> Bool {
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(accessibilityApp, Float(point.x), Float(point.y), &hit)
            switch result {
            case .success:
                guard let hit, Self.belongs(hit, to: pid) else { return false }
                return Self.conversationInputKind(hit) != .blocked
            case .notImplemented, .noValue, .attributeUnsupported, .cannotComplete:
                // The marked point is validated separately against the original window hit.
                return true
            default: return false
            }
        }

        func acceptsConversationPaste(at point: NSPoint) -> Bool {
            guard let focused = Self.element(accessibilityApp, kAXFocusedUIElementAttribute) else { return true }
            guard Self.belongs(focused, to: pid) else { return false }
            switch Self.conversationInputKind(focused) {
            case .editor: return Self.frame(of: focused)?.contains(point) == true
            case .unexposed: return true
            case .blocked: return false
            }
        }

        private enum ConversationInputKind { case editor, unexposed, blocked }

        private static func conversationInputKind(_ element: AXUIElement) -> ConversationInputKind {
            let role = value(element, kAXRoleAttribute) as? String
            let subrole = value(element, kAXSubroleAttribute) as? String
            guard role != "AXSearchField", subrole != "AXSearchField", subrole != kAXSecureTextFieldSubrole else {
                return .blocked
            }
            if isEditable(element) { return .editor }
            let containers = [kAXApplicationRole, kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole, "AXUnknown"]
            return role == nil || containers.contains(role ?? "") ? .unexposed : .blocked
        }

        func fieldFrame() -> NSRect? {
            guard let field, Self.value(window, kAXMinimizedAttribute) as? Bool != true else { return nil }
            return Self.frame(of: field)
        }

        func windowFrame() -> NSRect? {
            guard Self.value(window, kAXMinimizedAttribute) as? Bool != true else { return nil }
            return Self.frame(of: window)
        }

        func changeWindowFrame(to requested: NSRect) -> NSRect? {
            guard !application.isTerminated, let before = windowFrame(), let desktopTop = NSScreen.screens.first?.frame.maxY else { return nil }
            let needsResize = requested.size != before.size
            let needsMove = requested.origin != before.origin || requested.maxY != before.maxY
            if needsResize && !Self.isSettable(window, kAXSizeAttribute) { return before }
            if needsMove && !Self.isSettable(window, kAXPositionAttribute) { return before }

            if needsMove {
                var origin = CGPoint(x: requested.minX, y: desktopTop - requested.maxY)
                guard let value = AXValueCreate(.cgPoint, &origin),
                      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success else { return windowFrame() }
            }
            if needsResize {
                var size = requested.size
                if let value = AXValueCreate(.cgSize, &size) {
                    _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
                }
            }
            return windowFrame()
        }

        func anchorFrame() -> NSRect? {
            guard let field, let fieldBounds = fieldFrame() else { return nil }
            if let composer {
                if let bounds = composerFrame(composer, around: fieldBounds) { return bounds }
                if let replacement = Self.composerGroup(around: field, bounds: fieldBounds, in: window, conversation: conversationApp),
                   let bounds = Self.frame(of: replacement) { return bounds }
            }
            return CompactPromptGeometry.editorAnchor(fieldBounds, for: application.bundleIdentifier)
        }

        func verifiedComposerFrame() -> NSRect? {
            guard let composer, let editor = fieldFrame() else { return nil }
            return composerFrame(composer, around: editor)
        }

        func calibratedSelection(_ selection: WeChatRegionPicker.Selection, composer: NSRect?) -> WeChatRegionPicker.Selection {
            guard conversationApp == .feishu, let composer, composer.contains(selection.focusPoint),
                  let editor = fieldFrame(), composer.contains(editor),
                  (selection.frame.minX...selection.frame.maxX).contains(editor.midX) else { return selection }
            let point = NSPoint(x: editor.minX + min(24, editor.width / 2), y: editor.midY)
            return WeChatRegionPicker.Selection(frame: selection.frame, focusPoint: point)
        }

        private func composerFrame(_ composer: AXUIElement, around editor: NSRect) -> NSRect? {
            guard let outer = Self.frame(of: composer) else { return nil }
            if CompactPromptGeometry.wraps(outer, around: editor) { return outer }
            guard conversationApp == .feishu, CompactPromptGeometry.wrapsInlineComposer(outer, around: editor),
                  windowFrame()?.contains(outer) == true else { return nil }
            return outer
        }

        private static func composerGroup(around field: AXUIElement, bounds: NSRect, in window: AXUIElement,
                                          conversation: ConversationApp?) -> AXUIElement? {
            var branch = field
            for _ in 0..<5 {
                guard let parent = element(branch, kAXParentAttribute), !CFEqual(parent, branch), !CFEqual(parent, window) else { break }
                AXUIElementSetMessagingTimeout(parent, 0.15)
                guard let role = value(parent, kAXRoleAttribute) as? String,
                      ![kAXApplicationRole, kAXWindowRole, "AXWebArea", kAXSplitGroupRole].contains(role) else { break }
                if role == kAXGroupRole, let outer = frame(of: parent) {
                    let standard = CompactPromptGeometry.wraps(outer, around: bounds)
                    let inline = conversation == .feishu && CompactPromptGeometry.wrapsInlineComposer(outer, around: bounds) &&
                        frame(of: window)?.contains(outer) == true
                    if (standard || inline), hasActionSibling(in: parent, excluding: branch, boundedBy: outer,
                                                               outside: bounds, trailingOnly: !standard) {
                        return parent
                    }
                }
                branch = parent
            }
            return nil
        }

        private static func hasActionSibling(in group: AXUIElement, excluding branch: AXUIElement,
                                             boundedBy outer: NSRect, outside editor: NSRect, trailingOnly: Bool) -> Bool {
            var remainingNodes = 48
            return children(of: group).contains { sibling in
                !CFEqual(sibling, branch) && hasComposerAction(in: sibling, boundedBy: outer, outside: editor,
                                                              trailingOnly: trailingOnly, remainingDepth: 2, remainingNodes: &remainingNodes)
            }
        }

        private static func hasComposerAction(in node: AXUIElement, boundedBy outer: NSRect,
                                              outside editor: NSRect, trailingOnly: Bool,
                                              remainingDepth: Int, remainingNodes: inout Int) -> Bool {
            guard remainingNodes > 0 else { return false }
            remainingNodes -= 1
            AXUIElementSetMessagingTimeout(node, 0.15)
            guard let role = value(node, kAXRoleAttribute) as? String else { return false }
            let controls = [kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole]
            if controls.contains(role), let bounds = frame(of: node) {
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                guard outer.contains(center), !editor.contains(center) else { return false }
                return !trailingOnly || (center.x > editor.maxX && (editor.minY...editor.maxY).contains(center.y))
            }
            guard remainingDepth > 0, role == kAXGroupRole || role == kAXToolbarRole else { return false }
            return children(of: node).contains { child in
                hasComposerAction(in: child, boundedBy: outer, outside: editor,
                                  trailingOnly: trailingOnly, remainingDepth: remainingDepth - 1, remainingNodes: &remainingNodes)
            }
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

        private static func currentWindow(in app: AXUIElement) -> AXUIElement? {
            element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
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

    private struct ConversationRegion {
        let window: AXUIElement
        let windowSize: CGSize
        let relativeSelection: CGRect
        let relativeFocusPoint: NSPoint

        init(window: AXUIElement, windowFrame: NSRect, selection: WeChatRegionPicker.Selection) {
            self.window = window
            windowSize = windowFrame.size
            relativeSelection = selection.frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
            relativeFocusPoint = NSPoint(x: selection.focusPoint.x - windowFrame.minX, y: selection.focusPoint.y - windowFrame.minY)
        }

        func focusPoint(in frame: NSRect) -> NSPoint {
            NSPoint(x: frame.minX + relativeFocusPoint.x, y: frame.minY + relativeFocusPoint.y)
        }
    }
}

private enum CompactPromptGeometry {
    static func editorAnchor(_ editor: CGRect, for bundleIdentifier: String?) -> CGRect {
        // These apps can expose the text area without the padding above it in the visual composer.
        switch bundleIdentifier?.lowercased() {
        case "com.google.geminimacos", "com.tencent.workbuddy.mac", ConversationApp.feishu.rawValue:
            return CGRect(x: editor.minX, y: editor.minY, width: editor.width, height: editor.height + 16)
        default:
            return editor
        }
    }

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

    static func wrapsInlineComposer(_ group: CGRect, around editor: CGRect) -> Bool {
        // Feishu keeps its composer actions on the same row to the right of the editor.
        (0...24).contains(editor.minX - group.minX) && (48...360).contains(group.maxX - editor.maxX) &&
            (0...24).contains(group.maxY - editor.maxY) && (0...24).contains(editor.minY - group.minY)
    }
}

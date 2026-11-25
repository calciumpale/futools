import AppKit
import Combine
import SwiftUI

struct CompactWeChatChoice: Identifiable, Equatable {
    let id: Int
    let text: String
    let detail: String?
}

@MainActor
final class CompactWeChatControls: ObservableObject {
    enum Phase: Equatable {
        case idle, confirming, capturing, choosingTarget, suggesting, choosingReply, inserting, failed(String)

        var isBusy: Bool { isGenerating || self == .inserting }

        fileprivate var isGenerating: Bool { self == .capturing || self == .suggesting }

        fileprivate var actionTitle: String {
            switch self {
            case .confirming: return "同意并建议"
            case .capturing, .suggesting, .choosingTarget, .choosingReply: return "取消"
            case .idle, .inserting, .failed: return "建议回复"
            }
        }

        fileprivate var choiceTitle: String? {
            switch self {
            case .choosingTarget: return "选一句对方说的话"
            case .choosingReply: return "选一条回复"
            default: return nil
            }
        }
    }

    @Published var isActive = false
    @Published var appName = "微信"
    @Published var phase: Phase = .idle
    @Published var canPressAnywhere = false
    @Published var hasScreenshot = false
    @Published var hasSelectedRegion = false
    @Published var captureIsRestricted = false
    @Published var pastedTextPreview: String?
    @Published var choices: [CompactWeChatChoice] = []
    @Published var replyCount = 1
    @Published var replyTone: DeepSeekPromptAPI.WeChatTone = .natural
    @Published var replyTargetPreview: String?
    @Published var insertionNotice: String?
    var onSuggest: (() -> Void)?
    var onInsert: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSelectRegion: (() -> Void)?
    var onPasteContext: (() -> Void)?
    var onPasteScreenshot: ((NSPasteboard) -> Bool)?
    var onRemoveScreenshot: (() -> Void)?
    var onChoose: ((Int) -> Void)?
    var onSetReplyCount: ((Int) -> Void)?
    var onSetReplyTone: ((DeepSeekPromptAPI.WeChatTone) -> Void)?
    var alwaysOffersPastedContext = false

    fileprivate var insertionProgress: String { "正在插入\(appName)…" }
    fileprivate var restrictedCaptureHint: String { "当前\(appName)会话限制截图，可粘贴聊天文字或截图。" }

    fileprivate var needsPastedContext: Bool {
        guard captureIsRestricted, !hasScreenshot, pastedTextPreview == nil else { return false }
        switch phase {
        case .idle, .inserting, .failed: return true
        default: return false
        }
    }
}

@MainActor
struct CompactPromptView: View {
    static let baseHeight: CGFloat = 48
    private static let feedbackHeight: CGFloat = 34
    private static let weChatEditorHeight: CGFloat = 62
    private static let weChatActionsHeight: CGFloat = 34
    private static let weChatChoiceHeight: CGFloat = 216
    private static let footerSettingsMinimumWidth: CGFloat = 346
    private static let fullSettingsMinimumWidth: CGFloat = 380
    private static let weChatConsent = "截图在本机识别。聊天文字、所选消息、回复意图和语气会发送给 DeepSeek。"

    @ObservedObject var optimizer: PromptOptimizer
    @ObservedObject var voice: VoiceInputController
    @ObservedObject private var weChat: CompactWeChatControls
    let optimize: () -> Void
    let optimizeFromKeyboard: () -> Void
    let onBeginVoice: () -> Void
    let onEndVoice: () -> Void
    let onCancelVoice: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        optimizer: PromptOptimizer, voice: VoiceInputController,
        optimize: @escaping () -> Void, optimizeFromKeyboard: @escaping () -> Void,
        onBeginVoice: @escaping () -> Void, onEndVoice: @escaping () -> Void, onCancelVoice: @escaping () -> Void,
        weChat: CompactWeChatControls? = nil
    ) {
        self.optimizer = optimizer
        self.voice = voice
        self.weChat = weChat ?? CompactWeChatControls()
        self.optimize = optimize
        self.optimizeFromKeyboard = optimizeFromKeyboard
        self.onBeginVoice = onBeginVoice
        self.onEndVoice = onEndVoice
        self.onCancelVoice = onCancelVoice
    }

    private var colors: DockColors { DockColors(dark: scheme == .dark) }

    private var canOptimize: Bool {
        voice.phase == .idle && !optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasReplySettings: Bool { weChat.onSetReplyCount != nil || weChat.onSetReplyTone != nil }

    static func minimumHeight(weChat: CompactWeChatControls? = nil) -> CGFloat {
        weChat?.isActive == true ? weChatEditorHeight + weChatActionsHeight : baseHeight
    }

    static func panelHeight(optimizer: PromptOptimizer, voice: VoiceInputController, weChat: CompactWeChatControls? = nil) -> CGFloat {
        if let weChat, weChat.isActive, weChat.phase.choiceTitle != nil { return weChatChoiceHeight }
        let minimum = minimumHeight(weChat: weChat)
        return feedback(optimizer: optimizer, voice: voice, weChat: weChat) == nil ? minimum : minimum + feedbackHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        GeometryReader { geometry in
            Group {
                if weChat.isActive, let title = weChat.phase.choiceTitle {
                    choicePanel(title: title)
                        .id(title)
                        .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                } else {
                    editorPanel(size: geometry.size)
                        .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
            .animation(DockMotion.page(reduceMotion: reduceMotion), value: weChat.phase.choiceTitle)
        }
        .background(colors.surface, in: shape)
        .overlay {
            shape.strokeBorder(colors.outline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .tint(colors.action)
    }

    private func editorPanel(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if size.height >= Self.minimumHeight(weChat: weChat) + Self.feedbackHeight - 0.5,
               let feedback = Self.feedback(optimizer: optimizer, voice: voice, weChat: weChat) {
                Text(feedback.text)
                    .font(.system(size: 12))
                    .contentTransition(.opacity)
                    .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: feedback.text)
                    .foregroundStyle(feedback.isError ? colors.warning : colors.secondary)
                    .lineLimit(2)
                    .help(feedback.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: Self.feedbackHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(colors.line).frame(height: 1)
                    }
            }

            if weChat.isActive {
                if weChat.phase == .confirming {
                    weChatNotice(Self.weChatConsent)
                } else {
                    inputRow(narrow: size.width < 280, isWeChat: true,
                             showsReplySettings: hasReplySettings && size.width < Self.footerSettingsMinimumWidth)
                }
                weChatActions(width: size.width)
            } else {
                inputRow(narrow: size.width < 280)
            }
        }
    }

    private func weChatNotice(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(colors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: Self.weChatEditorHeight)
    }

    private func choicePanel(title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.ink)
                        .accessibilityAddTraits(.isHeader)
                    if weChat.phase == .choosingReply, let target = weChat.replyTargetPreview {
                        Text("回复这句：\(target)")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(1)
                            .help(target)
                    }
                }
                Spacer(minLength: 4)
                cancelWeChatButton
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .frame(height: 43)
            Rectangle().fill(colors.line).frame(height: 1)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(weChat.choices) { choice in
                        choiceButton(choice)
                    }
                }
                .padding(8)
            }
            .id(title)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func choiceButton(_ choice: CompactWeChatChoice) -> some View {
        Button { weChat.onChoose?(choice.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(colors.preview, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .disabled(weChat.onChoose == nil)
    }

    private func inputRow(narrow: Bool, isWeChat: Bool = false, showsReplySettings: Bool = false) -> some View {
        HStack(spacing: 10) {
            PaletteTextEditor(
                text: $optimizer.draft, label: isWeChat ? "回复草稿" : "提示词草稿", fontSize: 14,
                textColor: colors.ink, accentColor: colors.accent, placeholder: isWeChat ? "想怎么回（可选）" : "输入提示词",
                placeholderColor: colors.secondary, fixedViewportHeight: isWeChat ? 48 : 32,
                fixedTextVerticalInset: isWeChat ? 6 : nil,
                isSearchEditor: true, onOptimize: isWeChat ? nil : optimizeFromKeyboard,
                onPasteImage: isWeChat ? weChat.onPasteScreenshot : nil
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                VoicePressButton(
                    phase: voice.phase, isEnabled: !optimizer.isOptimizing && (!isWeChat || !weChat.phase.isBusy),
                    canPressAnywhere: weChat.canPressAnywhere,
                    onBegin: onBeginVoice, onEnd: onEndVoice, onCancel: onCancelVoice, style: .compact
                )
                if isWeChat {
                    if showsReplySettings { replySettingsMenu(label: "\(weChat.replyCount)") }
                } else {
                    optimizeButton(showsIcon: !narrow)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: isWeChat ? Self.weChatEditorHeight : Self.baseHeight)
    }

    private var replySettingsSummary: String { "\(weChat.replyCount) 条 · \(weChat.replyTone.title)" }

    private func replySettingsMenu(label: String) -> some View {
        Menu {
            if let setCount = weChat.onSetReplyCount {
                Section("回复条数") {
                    ForEach(1...3, id: \.self) { count in
                        replySetting("\(count) 条", selected: count == weChat.replyCount) { setCount(count) }
                    }
                }
            }
            if let setTone = weChat.onSetReplyTone {
                Section("回复语气") {
                    ForEach(DeepSeekPromptAPI.WeChatTone.allCases, id: \.self) { tone in
                        replySetting(tone.title, selected: tone == weChat.replyTone) { setTone(tone) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(label).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colors.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(colors.secondary)
        .padding(.horizontal, 5)
        .frame(height: 26)
        .background(colors.control, in: RoundedRectangle(cornerRadius: 6))
        .disabled(weChat.phase.isBusy || voice.phase != .idle)
        .accessibilityLabel("回复设置")
        .accessibilityValue(replySettingsSummary)
        .help("回复设置 · \(replySettingsSummary)")
    }

    private func replySetting(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func weChatActions(width: CGFloat) -> some View {
        let phase = weChat.phase
        let hasText = !optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isConfirming = phase == .confirming
        let isInserting = phase == .inserting
        let hasPastedText = weChat.pastedTextPreview != nil
        let showsAttachment = !isConfirming && (weChat.hasScreenshot || hasPastedText)
        let condensed = width < 280 && showsAttachment
        let contextWidth: CGFloat = condensed ? 24 : 28
        let needsPaste = !weChat.alwaysOffersPastedContext && weChat.needsPastedContext
        let waitingForContext = weChat.alwaysOffersPastedContext && weChat.needsPastedContext
        let canUseSecondaryActions = !phase.isBusy && voice.phase == .idle
        return HStack(spacing: condensed ? 3 : 7) {
            if !isConfirming && !weChat.alwaysOffersPastedContext {
                if weChat.appName == ConversationApp.feishu.name, !needsPaste, let pasteContext = weChat.onPasteContext {
                    conversationContextMenu(paste: pasteContext, width: contextWidth, isEnabled: canUseSecondaryActions)
                } else if let selectRegion = weChat.onSelectRegion {
                    Button(action: selectRegion) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(colors.secondary)
                            .frame(width: contextWidth, height: 28)
                            .contentShape(Rectangle())
                            .opacity(canUseSecondaryActions ? 1 : 0.55)
                    }
                    .buttonStyle(DockPressStyle())
                    .disabled(!canUseSecondaryActions)
                    .accessibilityLabel("重新框选消息区")
                    .help("重新框选消息区")
                }
            }
            if showsAttachment && !weChat.alwaysOffersPastedContext {
                attachmentButton(title: hasPastedText ? "文字" : "截图", condensed: condensed,
                                 isEnabled: canUseSecondaryActions && weChat.onRemoveScreenshot != nil)
            }
            if !isConfirming && hasReplySettings && width >= Self.footerSettingsMinimumWidth {
                replySettingsMenu(label: width < Self.fullSettingsMinimumWidth ? "\(weChat.replyCount) 条" : replySettingsSummary)
            }
            Spacer(minLength: 0)
            if isConfirming {
                cancelWeChatButton
            } else if hasText {
                weChatSecondaryButton(isInserting ? "插入中" : "插入", width: condensed ? 42 : 52) { weChat.onInsert?() }
                    .disabled(!canUseSecondaryActions || weChat.onInsert == nil)
                    .accessibilityLabel("插入\(weChat.appName)")
                    .help(isInserting ? weChat.insertionProgress : "将回复插入\(weChat.appName)输入框")
            }

            let action = needsPaste ? weChat.onPasteContext : weChat.onSuggest
            let enabled = !isInserting && !waitingForContext && voice.phase == .idle && action != nil
            let primaryWidth: CGFloat = needsPaste ? 108 : (condensed ? 90 : 96)
            Button { action?() } label: {
                HStack(spacing: 5) {
                    DockActivityGlyph(isBusy: phase.isGenerating, idleSymbol: needsPaste ? "doc.on.clipboard" : "sparkles")
                    Text(needsPaste ? "粘贴聊天内容" : phase.actionTitle)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled && !phase.isBusy ? Color.white : colors.secondary)
                .frame(width: primaryWidth, height: 28)
                .background(enabled && !phase.isBusy ? colors.action : colors.control, in: RoundedRectangle(cornerRadius: 7))
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: phase.actionTitle)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: enabled)
            }
            .buttonStyle(DockPressStyle())
            .disabled(!enabled)
            .help(Self.replyFeedback(for: weChat)?.text ?? (needsPaste ? weChat.restrictedCaptureHint : Self.weChatConsent))
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 6)
        .frame(height: Self.weChatActionsHeight)
    }

    private func conversationContextMenu(paste: @escaping () -> Void, width: CGFloat, isEnabled: Bool) -> some View {
        Menu {
            if let selectRegion = weChat.onSelectRegion { Button("重新框选消息区", action: selectRegion) }
            Button("粘贴聊天内容", action: paste)
        } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: width, height: 28)
        .tint(colors.secondary)
        .disabled(!isEnabled)
        .accessibilityLabel("会话内容")
        .help("重新框选消息区或粘贴聊天内容")
    }

    private func attachmentButton(title: String, condensed: Bool, isEnabled: Bool) -> some View {
        Button { weChat.onRemoveScreenshot?() } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: .medium))
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(colors.accent)
            .frame(width: condensed ? 44 : 53, height: 26)
            .background(colors.selection, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(DockPressStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("移除\(title)")
        .help("移除\(title)")
    }

    private var cancelWeChatButton: some View {
        weChatSecondaryButton("取消") { weChat.onCancel?() }
            .disabled(weChat.onCancel == nil)
    }

    private func weChatSecondaryButton(_ title: String, width: CGFloat = 52, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        return Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.ink)
                .frame(width: width, height: 28)
                .background(colors.control, in: shape)
                .overlay { shape.strokeBorder(colors.outline).allowsHitTesting(false) }
                .opacity(weChat.phase.isBusy || voice.phase != .idle ? 0.55 : 1)
        }
        .buttonStyle(DockPressStyle())
    }

    private func optimizeButton(showsIcon: Bool) -> some View {
        let isReady = canOptimize && !optimizer.isOptimizing
        return Button {
            if optimizer.isOptimizing { optimizer.cancel() } else { optimize() }
        } label: {
            HStack(spacing: 5) {
                if showsIcon || optimizer.isOptimizing {
                    DockActivityGlyph(isBusy: optimizer.isOptimizing, idleSymbol: "sparkles")
                }
                Text(optimizer.isOptimizing ? "取消优化" : "优化提示词")
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isReady ? Color.white : colors.secondary)
            .frame(width: showsIcon ? 94 : 72, height: 30)
            .background(isReady ? colors.action : colors.control, in: RoundedRectangle(cornerRadius: 8))
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: optimizer.isOptimizing)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isReady)
        }
        .buttonStyle(DockPressStyle())
        .disabled(!canOptimize && !optimizer.isOptimizing)
        .accessibilityLabel(optimizer.isOptimizing ? "取消优化" : "优化提示词")
        .help(optimizer.isOptimizing ? "取消本次优化" : "优化提示词（⌘↩）")
    }

    private static func feedback(optimizer: PromptOptimizer, voice: VoiceInputController, weChat: CompactWeChatControls?) -> Feedback? {
        if let weChat, weChat.isActive,
           weChat.phase == .confirming || weChat.phase.choiceTitle != nil { return nil }
        switch voice.phase {
        case .requestingPermission: return Feedback(text: "等待麦克风和语音识别授权…")
        case .recording: return Feedback(text: voice.message ?? "正在录音，松开后转写")
        case .finishing: return Feedback(text: "正在转写语音…")
        case .idle:
            if let weChat, weChat.isActive {
                if let status = replyFeedback(for: weChat) { return status }
                if let notice = weChat.insertionNotice { return Feedback(text: notice) }
                if weChat.needsPastedContext { return Feedback(text: weChat.restrictedCaptureHint) }
                if let target = weChat.replyTargetPreview { return Feedback(text: "回复这句：\(target)") }
                if let preview = weChat.pastedTextPreview { return Feedback(text: "聊天文字：\(preview)") }
                return voice.message.map { Feedback(text: $0) }
            }
            if let error = optimizer.errorMessage { return Feedback(text: error, isError: true) }
            return voice.message.map { Feedback(text: $0) }
        }
    }

    private static func replyFeedback(for controls: CompactWeChatControls) -> Feedback? {
        switch controls.phase {
        case .capturing: return Feedback(text: "正在识别\(controls.appName)聊天…")
        case .suggesting: return Feedback(text: "正在生成回复建议…")
        case .inserting: return Feedback(text: controls.insertionProgress)
        case .failed(let error): return Feedback(text: error, isError: true)
        case .idle, .confirming, .choosingTarget, .choosingReply: return nil
        }
    }

    private struct Feedback {
        let text: String
        var isError = false
    }
}

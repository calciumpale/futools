import AppKit
import SwiftUI

private typealias ReplyState<Value> = SwiftUI.State<Value>

@MainActor
struct CopilotReplyView: View {
    @ObservedObject var optimizer: PromptOptimizer
    @ObservedObject var voice: VoiceInputController
    @ObservedObject var controls: CompactWeChatControls
    let libraryCount: Int
    let theme: CopilotTheme
    let onBeginVoice: () -> Void
    let onEndVoice: () -> Void
    let onCancelVoice: () -> Void
    let onShowToast: (String, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ReplyState private var contextExpanded = false
    @ReplyState private var copiedDraft = false
    @ReplyState private var copiedCandidateKey: String?
    @ReplyState private var copyResetTask: Task<Void, Never>?

    private static let quickIntents: [(label: String, intent: String)] = [
        ("确认收到", "确认收到，并告知后续安排"),
        ("约个时间", "礼貌确认方便沟通的具体时间"),
        ("礼貌婉拒", "委婉表达目前不方便或暂不需要"),
        ("稍后回复", "先告知已看到，确认细节后再回复"),
        ("请补充细节", "礼貌请对方补充更具体的信息")
    ]

    private var colors: DockColors { theme.base }
    private var trimmedDraft: String { optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDraft: Bool { !trimmedDraft.isEmpty }
    private var isBusy: Bool { controls.phase.isBusy || controls.isPolishing || voice.phase != .idle }

    private var hasContext: Bool {
        controls.pastedTextPreview != nil || controls.hasScreenshot || controls.hasSelectedRegion
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    contextCard

                    if controls.phase == .confirming {
                        consentCard
                            .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    } else if controls.phase == .choosingTarget {
                        targetPickerCard
                            .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    } else if controls.phase == .choosingReply {
                        candidateRepliesCard
                            .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    }

                    draftCard
                    styleControlsCard

                    if controls.phase != .choosingReply && !controls.recentSuggestions.isEmpty {
                        candidateRepliesCard
                            .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    }

                    if let banner = statusBanner {
                        statusCard(banner)
                            .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: controls.phase)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: controls.recentSuggestions)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(colors.line).frame(height: 1)
            actionFooter
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    // MARK: - Context Card

    private var contextCard: some View {
        let hasPastedText = controls.pastedTextPreview != nil
        let hasScreenshot = controls.hasScreenshot
        let isRestricted = controls.captureIsRestricted

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CopilotSectionTitle(title: "会话上下文", symbol: "text.bubble", theme: theme)
                Spacer(minLength: 4)
                contextStatusBadge
            }
            .frame(height: 20)

            HStack(spacing: 7) {
                contextActionButton(
                    title: controls.hasSelectedRegion ? "重新框选" : "框选消息",
                    symbol: "viewfinder",
                    active: controls.hasSelectedRegion && !hasPastedText && !hasScreenshot,
                    disabled: isBusy || isRestricted || controls.onSelectRegion == nil
                ) {
                    controls.onSelectRegion?()
                }
                .help(isRestricted ? controls.restrictedCaptureHint : "框选聊天窗口里的消息区域")

                contextActionButton(
                    title: hasPastedText || hasScreenshot ? "重新粘贴" : "粘贴内容",
                    symbol: "doc.on.clipboard",
                    active: hasPastedText || hasScreenshot,
                    disabled: isBusy || controls.onPasteContext == nil
                ) {
                    controls.onPasteContext?()
                }
                .help("读取剪贴板中的聊天文字或截图（也可在草稿区按 ⌘V 粘贴截图）")
            }

            if let image = controls.screenshotPreview, hasScreenshot {
                HStack(spacing: 9) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: 58, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.cardBorder, lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已载入聊天截图")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(colors.ink)
                        Text("仅在本机识别文字，原图不上传")
                            .font(.system(size: 10.5))
                            .foregroundStyle(colors.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
                .background(theme.cardSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let fullText = controls.pastedFullText, !fullText.isEmpty {
                Button {
                    contextExpanded.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Text(fullText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(colors.body)
                            .lineLimit(contextExpanded ? 8 : 2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 2) {
                            Image(systemName: contextExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(colors.secondary)
                            Text("\(fullText.count)字")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(colors.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.cardSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(contextExpanded ? "收起聊天上下文" : "展开查看粘贴的聊天文字")
            }

            if let target = controls.replyTargetPreview, controls.phase != .choosingTarget {
                HStack(spacing: 5) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(colors.accent)
                    Text("回复：\(target)")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(target)
            }

            if controls.needsPastedContext {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.warning)
                        .padding(.top, 1)
                    Text(controls.restrictedCaptureHint)
                        .font(.system(size: 11))
                        .foregroundStyle(colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(10)
        .copilotCard(theme, cornerRadius: 10)
    }

    @ViewBuilder
    private var contextStatusBadge: some View {
        if controls.pastedTextPreview != nil || controls.hasScreenshot {
            let label = controls.pastedTextPreview != nil ? "已粘贴文字" : "已粘贴截图"
            Button { controls.onRemoveScreenshot?() } label: {
                HStack(spacing: 4) {
                    Circle().fill(theme.success).frame(width: 6, height: 6)
                    Text(label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.success)
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.success.opacity(0.8))
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(theme.successSoft, in: Capsule(style: .continuous))
            }
            .buttonStyle(DockPressStyle())
            .disabled(isBusy)
            .help("清除已粘贴的上下文")
        } else if controls.hasSelectedRegion {
            HStack(spacing: 4) {
                Circle().fill(theme.success).frame(width: 6, height: 6)
                Text("已框选区域")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.success)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(theme.successSoft, in: Capsule(style: .continuous))
        } else {
            Text("待获取")
                .font(.system(size: 10.5))
                .foregroundStyle(colors.secondary)
        }
    }

    private func contextActionButton(
        title: String,
        symbol: String,
        active: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? colors.accent : colors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                active ? theme.accentSoft : colors.control,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? colors.accent.opacity(0.32) : theme.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(DockPressStyle())
        .disabled(disabled)
    }

    // MARK: - Consent Card

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.accent)
                Text("首次发送隐私确认")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(colors.ink)
            }
            Text("截图在本机识别。识别或粘贴的聊天文字、所选消息、回复意图和语气会发送给 DeepSeek 用于生成回复。")
                .font(.system(size: 11.5))
                .foregroundStyle(colors.body)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { controls.onCancel?() }
                    .buttonStyle(DockPressStyle())
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(colors.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(colors.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button("同意并建议") { controls.onSuggest?() }
                    .buttonStyle(DockPressStyle())
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 27)
                    .background(colors.action, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(11)
        .copilotCard(theme, cornerRadius: 10, focused: true)
    }

    // MARK: - Target Picker Card

    private var targetPickerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CopilotSectionTitle(title: "选一句对方说的话", symbol: "person.wave.2", theme: theme)
                Spacer()
                Button("取消") { controls.onCancel?() }
                    .buttonStyle(DockPressStyle())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondary)
            }

            VStack(spacing: 6) {
                ForEach(controls.choices) { choice in
                    Button { controls.onChoose?(choice.id) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.text)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(colors.ink)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = choice.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(colors.accent)
                                }
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(colors.secondary)
                                .padding(.top, 3)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.cardSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.cardBorder, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .buttonStyle(DockPressStyle())
                }
            }
        }
        .padding(10)
        .copilotCard(theme, cornerRadius: 10, focused: true)
    }

    // MARK: - Candidate Replies Card

    private var candidateRepliesCard: some View {
        let items: [(id: Int, text: String, fromPending: Bool)] = {
            if controls.phase == .choosingReply {
                return controls.choices.map { ($0.id, $0.text, true) }
            }
            return controls.recentSuggestions.enumerated().map { ($0.offset, $0.element, false) }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CopilotSectionTitle(
                    title: controls.phase == .choosingReply ? "选一条回复" : "候选回复",
                    symbol: "sparkles",
                    theme: theme
                )
                if controls.matchedLibraryCount > 0 {
                    Text("已参考 \(controls.matchedLibraryCount) 条资料")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(colors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accentSoft, in: Capsule(style: .continuous))
                }
                Spacer(minLength: 4)
                if controls.phase == .choosingReply {
                    Button("取消") { controls.onCancel?() }
                        .buttonStyle(DockPressStyle())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondary)
                } else {
                    Button {
                        controls.onSuggest?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("换一批")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(colors.accent)
                    }
                    .buttonStyle(DockPressStyle())
                    .disabled(isBusy)
                }
            }

            VStack(spacing: 7) {
                ForEach(items, id: \.id) { item in
                    candidateRow(index: item.id, text: item.text, fromPending: item.fromPending)
                }
            }
        }
        .padding(10)
        .copilotCard(theme, cornerRadius: 10, focused: controls.phase == .choosingReply)
    }

    private func candidateRow(index: Int, text: String, fromPending: Bool) -> some View {
        let isSelected = !fromPending && trimmedDraft == text.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyKey = "\(index)::\(text)"
        let isCopied = copiedCandidateKey == copyKey

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if fromPending {
                    controls.onChoose?(index)
                } else {
                    optimizer.draft = text
                }
            } label: {
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? .white : colors.accent)
                        .frame(width: 18, height: 18)
                        .background(
                            isSelected ? colors.action : theme.accentSoft,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .padding(.top, 1)

                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(colors.ink)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button {
                    if fromPending {
                        controls.onChoose?(index)
                    } else {
                        optimizer.draft = text
                    }
                } label: {
                    Text(isSelected ? "当前草稿" : "填入草稿")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isSelected ? colors.accent : colors.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            isSelected ? theme.accentSoft : colors.control,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(DockPressStyle())

                Button {
                    if fromPending { controls.onChoose?(index) }
                    controls.onDirectInsertText?(text)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 9))
                        Text("直接插入")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(colors.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(DockPressStyle())
                .disabled(isBusy)

                Spacer(minLength: 2)

                CopilotIconHoverButton(
                    symbol: isCopied ? "checkmark" : "doc.on.doc",
                    theme: theme,
                    tint: isCopied ? theme.success : nil,
                    size: 22,
                    iconSize: 10,
                    helpText: isCopied ? "已复制" : "复制这条回复"
                ) {
                    CopilotPasteboard.copy(text)
                    copiedCandidateKey = copyKey
                    onShowToast("已复制候选回复", "checkmark.circle.fill")
                    scheduleCopyReset()
                }
            }
            .padding(.leading, 25)
        }
        .padding(9)
        .background(
            isSelected ? theme.accentSoft.opacity(0.45) : theme.cardSubtle,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? theme.cardBorderFocused : theme.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Style Controls (Tone, Count, Library Grounding)

    private var styleControlsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                CopilotSectionTitle(title: "回复风格", symbol: "slider.horizontal.3", theme: theme)
                if libraryCount > 0 {
                    CopilotPillToggle(
                        title: "资料库 \(libraryCount)",
                        symbol: "square.stack",
                        isOn: Binding(
                            get: { controls.useLibraryInReply },
                            set: { controls.onSetUseLibrary?($0) }
                        ),
                        theme: theme,
                        isDisabled: isBusy
                    )
                    .help("生成回复建议时自动检索匹配的本地文案与链接作为参考")
                }
                Spacer(minLength: 4)
                // Reply count segmented pill (1 / 2 / 3)
                HStack(spacing: 2) {
                    ForEach(1...3, id: \.self) { count in
                        let selected = controls.replyCount == count
                        Button {
                            controls.onSetReplyCount?(count)
                        } label: {
                            Text("\(count)条")
                                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? colors.accent : colors.secondary)
                                .padding(.horizontal, 6)
                                .frame(height: 21)
                                .background(
                                    selected ? theme.pillActive : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                                .shadow(color: selected ? theme.pillShadow : .clear, radius: 1, x: 0, y: 0.5)
                        }
                        .buttonStyle(DockPressStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(theme.pillTrack, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(isBusy)
                .help("每次生成的候选回复数量")
            }

            // Inline tone pills
            HStack(spacing: 5) {
                ForEach(DeepSeekPromptAPI.WeChatTone.allCases, id: \.self) { tone in
                    let selected = controls.replyTone == tone
                    Button {
                        controls.onSetReplyTone?(tone)
                    } label: {
                        Text(tone.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? colors.accent : colors.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 25)
                            .background(
                                selected ? theme.accentSoft : colors.control,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        selected ? colors.accent.opacity(theme.dark ? 0.36 : 0.26) : theme.cardBorder,
                                        lineWidth: 1
                                    )
                                    .allowsHitTesting(false)
                            }
                    }
                    .buttonStyle(DockPressStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .disabled(isBusy)
        }
        .padding(9)
        .copilotCard(theme, cornerRadius: 10)
    }

    // MARK: - Draft Composer Card

    private var draftCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CopilotSectionTitle(title: "回复意图 / 草稿", symbol: "square.and.pencil", theme: theme)
                Spacer(minLength: 4)
                if hasDraft {
                    Text("\(trimmedDraft.count) 字")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(colors.secondary)
                }
            }

            // Quick intent chips when draft is empty
            if !hasDraft && !isBusy {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Self.quickIntents, id: \.label) { item in
                            Button {
                                optimizer.draft = item.intent
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(colors.secondary)
                                    .padding(.horizontal, 8)
                                    .frame(height: 22)
                                    .background(theme.cardSubtle, in: Capsule(style: .continuous))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .strokeBorder(theme.cardBorder, lineWidth: 1)
                                            .allowsHitTesting(false)
                                    }
                            }
                            .buttonStyle(DockPressStyle())
                            .help("填入意图：\(item.intent)")
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            VStack(spacing: 0) {
                PaletteTextEditor(
                    text: $optimizer.draft,
                    label: "回复草稿",
                    fontSize: 13.5,
                    textColor: colors.ink,
                    accentColor: colors.accent,
                    placeholder: "写下想怎么回（可选），或直接编辑回复…",
                    placeholderColor: colors.secondary,
                    fixedViewportHeight: 74,
                    fixedTextVerticalInset: 6,
                    isSearchEditor: true,
                    onOptimize: triggerKeyboardSuggest,
                    onPasteImage: controls.onPasteScreenshot
                )
                .padding(.horizontal, 8)
                .padding(.top, 2)

                Rectangle().fill(colors.line.opacity(0.7)).frame(height: 1)

                // Draft utility bar
                HStack(spacing: 5) {
                    VoicePressButton(
                        phase: voice.phase,
                        isEnabled: !controls.phase.isBusy && !controls.isPolishing,
                        canPressAnywhere: controls.canPressAnywhere,
                        onBegin: onBeginVoice,
                        onEnd: onEndVoice,
                        onCancel: onCancelVoice,
                        style: .compact
                    )

                    // Standalone AI Polish button (works even without captured context!)
                    Button {
                        controls.onPolishDraft?()
                    } label: {
                        HStack(spacing: 4) {
                            DockActivityGlyph(isBusy: controls.isPolishing, idleSymbol: "wand.and.stars")
                            Text(controls.isPolishing ? "润色中" : "按\(controls.replyTone.title)语气润色")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(hasDraft && !isBusy ? colors.accent : colors.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            hasDraft && !isBusy ? theme.accentSoft : colors.control,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(DockPressStyle())
                    .disabled(!hasDraft || isBusy || controls.onPolishDraft == nil)
                    .help("无需聊天上下文，直接按「\(controls.replyTone.title)」语气润色当前草稿")

                    Spacer(minLength: 2)

                    if hasDraft {
                        CopilotIconHoverButton(
                            symbol: copiedDraft ? "checkmark" : "doc.on.doc",
                            theme: theme,
                            tint: copiedDraft ? theme.success : nil,
                            size: 24,
                            iconSize: 10.5,
                            helpText: copiedDraft ? "已复制" : "复制草稿"
                        ) {
                            CopilotPasteboard.copy(optimizer.draft)
                            copiedDraft = true
                            onShowToast("已复制草稿", "checkmark.circle.fill")
                            scheduleCopyReset()
                        }

                        CopilotIconHoverButton(
                            symbol: "xmark.circle",
                            theme: theme,
                            size: 24,
                            iconSize: 11,
                            helpText: "清空草稿"
                        ) {
                            optimizer.draft = ""
                        }
                        .disabled(isBusy)
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 34)
            }
            .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(10)
        .copilotCard(theme, cornerRadius: 10)
    }

    // MARK: - Status Banner

    private struct Banner {
        enum Kind { case info, success, error, busy }
        let kind: Kind
        let text: String
    }

    private var statusBanner: Banner? {
        switch voice.phase {
        case .requestingPermission: return Banner(kind: .busy, text: "等待麦克风和语音识别授权…")
        case .recording: return Banner(kind: .busy, text: voice.message ?? "正在录音，松开后转写")
        case .finishing: return Banner(kind: .busy, text: "正在转写语音…")
        case .idle:
            if controls.isPolishing { return Banner(kind: .busy, text: "正在按「\(controls.replyTone.title)」语气润色草稿…") }
            switch controls.phase {
            case .capturing: return Banner(kind: .busy, text: "正在识别\(controls.appName)聊天内容…")
            case .suggesting: return Banner(kind: .busy, text: "正在生成 \(controls.replyCount) 条\(controls.replyTone.title)回复建议…")
            case .inserting: return Banner(kind: .busy, text: controls.insertionProgress)
            case .failed(let message): return Banner(kind: .error, text: message)
            case .idle:
                if let notice = controls.insertionNotice {
                    return Banner(kind: .success, text: notice)
                }
                if let message = voice.message {
                    return Banner(kind: .info, text: message)
                }
                return nil
            case .confirming, .choosingTarget, .choosingReply:
                return nil
            }
        }
    }

    private func statusCard(_ banner: Banner) -> some View {
        let fg: Color
        let bg: Color
        switch banner.kind {
        case .busy:
            fg = colors.accent
            bg = theme.accentSoft
        case .success:
            fg = theme.success
            bg = theme.successSoft
        case .error:
            fg = colors.warning
            bg = theme.warningSoft
        case .info:
            fg = colors.secondary
            bg = theme.cardSubtle
        }
        return HStack(alignment: .center, spacing: 7) {
            switch banner.kind {
            case .busy:
                DockActivityGlyph(isBusy: true)
                    .foregroundStyle(fg)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(fg)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(fg)
            case .info:
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(fg)
            }
            Text(banner.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Bottom Action Footer

    private var actionFooter: some View {
        let phase = controls.phase
        let waitingForContext = controls.needsPastedContext
        let canSuggest = phase != .inserting && !controls.isPolishing && !waitingForContext && voice.phase == .idle && controls.onSuggest != nil
        let isGenerating = phase.isGenerating
        let canInsert = hasDraft && !isBusy && ![.confirming, .choosingTarget, .choosingReply].contains(phase) && controls.onInsert != nil

        return HStack(spacing: 8) {
            Button {
                controls.onSuggest?()
            } label: {
                HStack(spacing: 5) {
                    DockActivityGlyph(
                        isBusy: isGenerating,
                        idleSymbol: phase == .confirming ? "checkmark.shield" : "sparkles"
                    )
                    Text(phase.actionTitle)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isGenerating
                        ? colors.ink
                        : (hasDraft ? (canSuggest ? colors.accent : colors.secondary) : (canSuggest ? .white : colors.secondary))
                )
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    isGenerating
                        ? colors.control
                        : (hasDraft
                            ? (canSuggest ? theme.accentSoft : colors.control)
                            : (canSuggest ? colors.action : colors.control)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    if hasDraft && !isGenerating && canSuggest {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(colors.accent.opacity(0.28), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(DockPressStyle())
            .disabled(!canSuggest)
            .help(hasContext ? "结合上下文生成回复建议（⌘↩）" : "点击先框选消息或生成建议（⌘↩）")

            if hasDraft && phase != .confirming {
                Button {
                    controls.onInsert?()
                } label: {
                    HStack(spacing: 5) {
                        if phase == .inserting {
                            DockActivityGlyph(isBusy: true)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(phase == .inserting ? "插入中" : "插入\(controls.appName)")
                            .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canInsert ? .white : colors.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        canInsert ? colors.action : colors.control,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(DockPressStyle())
                .disabled(!canInsert)
                .help("将草稿填入\(controls.appName)输入框供核对后发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.headerSurface)
    }

    private func triggerKeyboardSuggest() {
        guard !isBusy, !controls.needsPastedContext else { return }
        if !hasContext && hasDraft {
            controls.onPolishDraft?()
        } else {
            controls.onSuggest?()
        }
    }

    private func scheduleCopyReset() {
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            copiedDraft = false
            copiedCandidateKey = nil
        }
    }
}

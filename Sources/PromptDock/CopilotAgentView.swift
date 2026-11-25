import SwiftUI

private typealias AgentState<Value> = SwiftUI.State<Value>

@MainActor
struct CopilotAgentView: View {
    @ObservedObject var agent: CopilotAgentModel
    let appName: String
    let theme: CopilotTheme
    @Binding var expandedSources: Set<CopilotSource.ID>
    let onStageAnswer: (String) -> Void
    let onDirectInsert: (String) -> Void
    let onSaveToLibrary: (String, String) -> Void
    let onShowToast: (String, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AgentState private var copiedTurnID: UUID?
    @AgentState private var collapsedSourceTurns: Set<UUID> = []
    @AgentState private var copyResetTask: Task<Void, Never>?

    private var colors: DockColors { theme.base }
    private var canAsk: Bool { !agent.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            conversationArea
            Rectangle().fill(colors.line).frame(height: 1)
            composerDock
        }
        .onDisappear { copyResetTask?.cancel() }
        .onChange(of: agent.sources.map(\.id)) { ids in
            let allIDs = Set(agent.turns.flatMap { $0.sources.map(\.id) }).union(ids)
            expandedSources.formIntersection(allIDs)
        }
    }

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if agent.turns.isEmpty {
                    emptyWelcome
                        .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(agent.turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }
                        Color.clear.frame(height: 2).id("agent-bottom")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onChange(of: agent.turns.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: agent.answer) { _ in
                scrollToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("agent-bottom", anchor: .bottom)
        } else {
            withAnimation(DockMotion.transition(reduceMotion: false)) {
                proxy.scrollTo("agent-bottom", anchor: .bottom)
            }
        }
    }

    private var emptyWelcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.accent)
                        .frame(width: 32, height: 32)
                        .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copilot Agent")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(colors.ink)
                        Text("结合本地资料、聊天上下文与联网搜索")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.secondary)
                    }
                }
            }
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 7) {
                CopilotSectionTitle(title: "快速提问", symbol: "bolt.fill", theme: theme)
                ForEach(starterPrompts, id: \.title) { item in
                    starterCard(item)
                }
            }

            if let error = agent.errorMessage {
                errorBanner(error, retryTurnID: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct StarterPrompt {
        let title: String
        let prompt: String
        let symbol: String
        let requiresChatContext: Bool
    }

    private var starterPrompts: [StarterPrompt] {
        var list: [StarterPrompt] = []
        if agent.hasChatContext {
            list.append(StarterPrompt(
                title: "总结当前对话要点",
                prompt: "请总结当前聊天记录里对方的核心问题、关键时间节点和待办事项。",
                symbol: "text.bubble",
                requiresChatContext: true
            ))
        }
        if agent.localLibraryCount > 0 {
            list.append(StarterPrompt(
                title: "从资料库提炼简短介绍",
                prompt: "请根据本地资料库，整理一段 3 句话以内、适合直接发给对方的简洁介绍。",
                symbol: "square.stack",
                requiresChatContext: false
            ))
        }
        list.append(StarterPrompt(
            title: "联网检索并给出参考来源",
            prompt: "帮我检索并梳理最新要点，附上参考来源：",
            symbol: "globe",
            requiresChatContext: false
        ))
        list.append(StarterPrompt(
            title: "起草委婉清晰的跟进话术",
            prompt: "帮我拟一段礼貌且直接的跟进消息，确认对方的进展和时间安排。",
            symbol: "wand.and.stars",
            requiresChatContext: false
        ))
        return list
    }

    private func starterCard(_ item: StarterPrompt) -> some View {
        Button {
            if item.requiresChatContext {
                agent.includeChatContext = true
            }
            if item.prompt.hasSuffix("：") {
                agent.question = item.prompt
            } else {
                agent.ask(item.prompt)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .frame(width: 24, height: 24)
                    .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(colors.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CopilotHoverRow(theme: theme, cornerRadius: 9))
        }
        .buttonStyle(DockPressStyle())
    }

    private func turnView(_ turn: CopilotAgentTurn) -> some View {
        let isCurrentWorking = agent.isWorking && agent.turns.last?.id == turn.id
        return VStack(alignment: .leading, spacing: 8) {
            // User question bubble
            HStack {
                Spacer(minLength: 26)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(turn.question)
                        .font(.system(size: 12.5))
                        .foregroundStyle(colors.ink)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if turn.usedChatContext {
                        Label("已结合聊天上下文", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(colors.accent)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(theme.userBubbleBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }

            // Assistant response card
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(colors.accent)
                    Text("Agent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.secondary)
                    if isCurrentWorking, let status = agent.phase.statusText {
                        HStack(spacing: 5) {
                            DockActivityGlyph(isBusy: true)
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(colors.secondary)
                        }
                        .padding(.leading, 4)
                    }
                    Spacer(minLength: 4)
                    if !isCurrentWorking {
                        CopilotIconHoverButton(
                            symbol: "arrow.clockwise",
                            theme: theme,
                            size: 22,
                            iconSize: 10,
                            helpText: "重新生成"
                        ) {
                            agent.retry(turnID: turn.id)
                        }
                        .disabled(agent.isWorking)
                    }
                }

                if let error = turn.errorMessage {
                    errorBanner(error, retryTurnID: turn.id)
                } else if !turn.answer.isEmpty {
                    CopilotMarkdownText(markdown: turn.answer, theme: theme, fontSize: 12.5)

                    // Per-message action bar
                    answerActionBar(turn)
                }

                if !turn.sources.isEmpty {
                    sourcesSection(for: turn)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .copilotCard(theme, cornerRadius: 11)
        }
    }

    private func answerActionBar(_ turn: CopilotAgentTurn) -> some View {
        let isCopied = copiedTurnID == turn.id
        return HStack(spacing: 5) {
            actionChip(title: "用作草稿", symbol: "arrow.uturn.left", primary: true) {
                onStageAnswer(turn.answer)
            }
            .help("填入回复草稿并切换到回复页")

            actionChip(title: "插入", symbol: "paperplane.fill", primary: false) {
                onDirectInsert(turn.answer)
            }
            .help("直接填入\(appName)输入框")

            Spacer(minLength: 2)

            CopilotIconHoverButton(
                symbol: isCopied ? "checkmark" : "doc.on.doc",
                theme: theme,
                tint: isCopied ? theme.success : nil,
                size: 24,
                iconSize: 10.5,
                helpText: isCopied ? "已复制" : "复制回答"
            ) {
                copyAnswer(turn)
            }

            CopilotIconHoverButton(
                symbol: "bookmark.badge.plus",
                theme: theme,
                size: 24,
                iconSize: 11,
                helpText: "存为资料库文案"
            ) {
                let title = String(turn.question.prefix(24))
                onSaveToLibrary(title, turn.answer)
            }
        }
        .padding(.top, 2)
        .disabled(agent.isWorking)
    }

    private func actionChip(title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(primary ? colors.accent : colors.ink)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                primary ? theme.accentSoft : colors.control,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(primary ? colors.accent.opacity(0.22) : theme.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(DockPressStyle())
    }

    private func sourcesSection(for turn: CopilotAgentTurn) -> some View {
        let collapsed = collapsedSourceTurns.contains(turn.id)
        return VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(colors.line).frame(height: 1)

            Button {
                if collapsed {
                    collapsedSourceTurns.remove(turn.id)
                } else {
                    collapsedSourceTurns.insert(turn.id)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colors.secondary)
                    Text("参考来源 · \(turn.sources.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(colors.secondary)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(DockPressStyle())

            if !collapsed {
                VStack(spacing: 4) {
                    ForEach(Array(turn.sources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source, number: index + 1)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: CopilotSource, number: Int) -> some View {
        let isExpanded = expandedSources.contains(source.id)
        let host = source.url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Button {
                    guard !source.excerpt.isEmpty else { return }
                    if isExpanded {
                        expandedSources.remove(source.id)
                    } else {
                        expandedSources.insert(source.id)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("\(number)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(colors.accent)
                            .frame(width: 16, height: 16)
                            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(colors.ink)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(source.isLocal ? "本地资料" : (host ?? "网页"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(colors.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 2)

                        if !source.excerpt.isEmpty {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(colors.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DockPressStyle())
                .disabled(source.excerpt.isEmpty)

                if let url = source.url, let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(colors.accent)
                            .frame(width: 22, height: 22)
                            .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(DockPressStyle())
                    .help("打开原文：\(url.absoluteString)")
                    .accessibilityLabel("打开原文：\(source.title)")
                }
            }

            if isExpanded && !source.excerpt.isEmpty {
                Text(source.excerpt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.secondary)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.cardSubtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func errorBanner(_ message: String, retryTurnID: UUID?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(colors.warning)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(colors.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let retryTurnID {
                Button("重试") { agent.retry(turnID: retryTurnID) }
                    .buttonStyle(DockPressStyle())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .disabled(agent.isWorking)
            }
        }
        .padding(9)
        .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var composerDock: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Scope toggle bar
            HStack(spacing: 5) {
                CopilotPillToggle(
                    title: "资料库",
                    symbol: "square.stack",
                    isOn: $agent.includeLibrary,
                    theme: theme,
                    isDisabled: agent.isWorking
                )
                .help("检索本地资料库作为回答参考")

                CopilotPillToggle(
                    title: "联网",
                    symbol: "globe",
                    isOn: $agent.searchWeb,
                    theme: theme,
                    isDisabled: agent.isWorking
                )
                .help("使用 DeepSeek 联网搜索获取实时信息")

                if agent.hasChatContext || agent.includeChatContext {
                    CopilotPillToggle(
                        title: "对话",
                        symbol: "bubble.left.and.bubble.right",
                        isOn: $agent.includeChatContext,
                        theme: theme,
                        isDisabled: agent.isWorking || !agent.hasChatContext
                    )
                    .help(agent.hasChatContext ? "结合当前会话的聊天记录回答" : "先在回复页粘贴或识别聊天记录后可用")
                }

                Spacer(minLength: 2)

                Image(systemName: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.secondary.opacity(0.8))
                    .help("提问、相关资料摘录及开启时的聊天文字会发送给 DeepSeek。原文件保留在本机。")

                if !agent.turns.isEmpty {
                    CopilotIconHoverButton(
                        symbol: "trash",
                        theme: theme,
                        size: 24,
                        iconSize: 10.5,
                        helpText: "清空对话"
                    ) {
                        agent.clearHistory()
                    }
                    .disabled(agent.isWorking)
                }
            }

            // Input card + send button
            HStack(alignment: .bottom, spacing: 7) {
                PaletteTextEditor(
                    text: $agent.question,
                    label: "Agent 问题",
                    fontSize: 13,
                    textColor: colors.ink,
                    accentColor: colors.accent,
                    placeholder: agent.turns.isEmpty ? "问点什么…（⌘↩ 发送）" : "继续追问…（⌘↩ 发送）",
                    placeholderColor: colors.secondary,
                    fixedTextVerticalInset: 6,
                    onOptimize: ask
                )
                .padding(.horizontal, 7)
                .frame(height: 54)
                .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }

                Button {
                    if agent.isWorking { agent.cancel() } else { ask() }
                } label: {
                    Image(systemName: agent.isWorking ? "stop.fill" : "arrow.up")
                        .font(.system(size: agent.isWorking ? 10 : 12.5, weight: .bold))
                        .foregroundStyle(agent.isWorking ? colors.ink : (canAsk ? .white : colors.secondary))
                        .frame(width: 32, height: 32)
                        .background(
                            agent.isWorking
                                ? colors.control
                                : (canAsk ? colors.action : colors.control),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(DockPressStyle())
                .disabled(!agent.isWorking && !canAsk)
                .help(agent.isWorking ? "停止生成" : "发送提问（⌘↩）")
                .accessibilityLabel(agent.isWorking ? "停止生成" : "发送提问")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.headerSurface)
    }

    private func ask() {
        guard canAsk, !agent.isWorking else { return }
        agent.ask()
    }

    private func copyAnswer(_ turn: CopilotAgentTurn) {
        CopilotPasteboard.copy(turn.answer)
        copiedTurnID = turn.id
        onShowToast("已复制回答", "checkmark.circle.fill")
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            if copiedTurnID == turn.id { copiedTurnID = nil }
        }
    }
}

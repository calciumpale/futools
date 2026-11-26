import SwiftUI

private typealias SidebarState<Value> = SwiftUI.State<Value>

@MainActor
struct CopilotSidebarView: View {
    @ObservedObject var optimizer: PromptOptimizer
    @ObservedObject var voice: VoiceInputController
    @ObservedObject var controls: CompactWeChatControls
    @ObservedObject var library: CopilotLibraryStore
    @ObservedObject var agent: CopilotAgentModel
    let onToggleDockSide: () -> Void
    let onClose: () -> Void
    let onStageMaterial: (CopilotMaterial) -> Void
    let onDirectInsertText: (String) -> Void
    let onStageAnswer: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabNamespace
    @SidebarState private var selectedTab: Tab = .reply
    @SidebarState private var expandedSources: Set<CopilotSource.ID> = []
    @SidebarState private var toast: ToastItem?
    @SidebarState private var toastTask: Task<Void, Never>?

    private struct ToastItem: Equatable {
        let id = UUID()
        let message: String
        let symbol: String
    }

    private var theme: CopilotTheme { CopilotTheme(dark: colorScheme == .dark) }
    private var colors: DockColors { theme.base }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(colors.line).frame(height: 1)
                ZStack(alignment: .topLeading) {
                    page
                        .id(selectedTab)
                        .transition(.asymmetric(insertion: DockMotion.pageReveal(reduceMotion: reduceMotion), removal: .identity))
                }
                .animation(DockMotion.page(reduceMotion: reduceMotion), value: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let toast {
                CopilotToastPill(message: toast.message, symbol: toast.symbol, theme: theme)
                    .padding(.bottom, 58)
                    .padding(.horizontal, 16)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: toast)
        .foregroundStyle(colors.ink)
        .tint(colors.action)
        .background(colors.background, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(theme.rimHighlight, lineWidth: 1)
                .padding(0.5)
                .allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(colors.outline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background {
            // Keyboard shortcuts for fast tab navigation (⌘1 / ⌘2 / ⌘3)
            Group {
                Button("") { selectedTab = .reply }.keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .library }.keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .agent }.keyboardShortcut("3", modifiers: .command)
            }
            .labelsHidden()
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onDisappear { toastTask?.cancel() }
    }

    private var toolbar: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 330
            HStack(spacing: compact ? 4 : 6) {
                if !controls.appName.isEmpty {
                    appBadge(compact: compact)
                }

                Spacer(minLength: 2)

                tabs(compact: compact)
                    .layoutPriority(1)

                Spacer(minLength: 2)

                HStack(spacing: 2) {
                    CopilotIconHoverButton(
                        symbol: controls.dockSide.toggleSymbol,
                        theme: theme,
                        size: compact ? 24 : 26,
                        iconSize: 11.5,
                        helpText: controls.dockSide.toggleHelp,
                        action: onToggleDockSide
                    )

                    CopilotIconHoverButton(
                        symbol: "xmark",
                        theme: theme,
                        size: compact ? 24 : 26,
                        iconSize: 11,
                        helpText: "关闭侧栏",
                        accessibilityLabel: "关闭侧栏",
                        action: onClose
                    )
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 44)
        .background(theme.headerSurface)
    }

    private func appBadge(compact: Bool) -> some View {
        let dotColor = theme.appTint(for: controls.appName)
        return HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: dotColor.opacity(0.45), radius: 2, x: 0, y: 0)
            Text(controls.appName)
                .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
                .foregroundStyle(colors.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: 24)
        .background(colors.control.opacity(0.85), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .help("已吸附到「\(controls.appName)」聊天窗口")
    }

    private func tabs(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let isSelected = tab == selectedTab
                Button {
                    if reduceMotion {
                        selectedTab = tab
                    } else {
                        withAnimation(DockMotion.feedback(reduceMotion: false)) {
                            selectedTab = tab
                        }
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        if !compact {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                        }
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? colors.accent : colors.secondary)
                    .padding(.horizontal, compact ? 7 : 9)
                    .frame(height: 25)
                    .background {
                        if isSelected {
                            let pill = RoundedRectangle(cornerRadius: 6, style: .continuous)
                            if reduceMotion {
                                pill
                                    .fill(theme.pillActive)
                                    .shadow(color: theme.pillShadow, radius: 1.5, x: 0, y: 0.5)
                            } else {
                                pill
                                    .fill(theme.pillActive)
                                    .shadow(color: theme.pillShadow, radius: 1.5, x: 0, y: 0.5)
                                    .matchedGeometryEffect(id: "copilot-active-tab", in: tabNamespace)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DockPressStyle())
                .accessibilityLabel(tab.accessibilityTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help("\(tab.accessibilityTitle)（⌘\(tab.shortcutNumber)）")
            }
        }
        .padding(2.5)
        .background(theme.pillTrack, in: RoundedRectangle(cornerRadius: 8.5, style: .continuous))
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .reply:
            CopilotReplyView(
                optimizer: optimizer,
                voice: voice,
                controls: controls,
                libraryCount: library.materials.count,
                theme: theme,
                onShowToast: showToast
            )
        case .library:
            CopilotLibraryView(
                store: library,
                appName: controls.appName,
                onStage: onStageMaterial,
                onStageToDraft: { text in
                    onStageAnswer(text)
                    selectedTab = .reply
                    showToast("已填入回复草稿", "arrow.uturn.left")
                },
                onShowToast: showToast
            )
        case .agent:
            CopilotAgentView(
                agent: agent,
                appName: controls.appName,
                theme: theme,
                expandedSources: $expandedSources,
                onStageAnswer: { answer in
                    onStageAnswer(answer)
                    selectedTab = .reply
                    showToast("已用作回复草稿", "arrow.uturn.left")
                },
                onDirectInsert: onDirectInsertText,
                onSaveToLibrary: saveAgentAnswerToLibrary,
                onShowToast: showToast
            )
        }
    }

    private func saveAgentAnswerToLibrary(title: String, body: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? "Agent 回答" : trimmedTitle
        let material = CopilotMaterial(kind: .text, title: finalTitle, body: body, tags: ["Agent"])
        Task {
            do {
                try await library.save(material)
                showToast("已存入资料库", "bookmark.fill")
            } catch {
                showToast(error.localizedDescription, "exclamationmark.triangle")
            }
        }
    }

    private func showToast(_ message: String, _ symbol: String) {
        let item = ToastItem(message: message, symbol: symbol)
        toast = item
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            if toast?.id == item.id {
                toast = nil
            }
        }
    }

    private enum Tab: CaseIterable {
        case reply, library, agent

        var title: String {
            switch self {
            case .reply: return "回复"
            case .library: return "资料"
            case .agent: return "Agent"
            }
        }

        var symbol: String {
            switch self {
            case .reply: return "bubble.left.and.text.bubble.right"
            case .library: return "square.stack"
            case .agent: return "sparkles"
            }
        }

        var shortcutNumber: String {
            switch self {
            case .reply: return "1"
            case .library: return "2"
            case .agent: return "3"
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .reply: return "建议回复"
            case .library: return "资料库"
            case .agent: return "Agent"
            }
        }
    }
}

import SwiftUI

private typealias SidebarState<Value> = SwiftUI.State<Value>

@MainActor
struct CopilotSidebarView: View {
    let appName: String
    let replyContent: AnyView
    let libraryContent: AnyView
    let agent: CopilotAgentModel
    let onClose: () -> Void
    let onStageAnswer: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SidebarState private var selectedTab: Tab = .reply
    @SidebarState private var expandedSources: Set<CopilotSource.ID> = []

    private var colors: DockColors { DockColors(dark: colorScheme == .dark) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
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
        .foregroundStyle(colors.ink)
        .tint(colors.action)
        .background(colors.background, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(colors.outline).allowsHitTesting(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !appName.isEmpty {
                Text(appName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 78, alignment: .leading)
                    .help(appName)
            }
            Spacer(minLength: 0)
            tabs.layoutPriority(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DockPressStyle())
            .accessibilityLabel("关闭侧栏")
            .help("关闭侧栏")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let isSelected = tab == selectedTab
                Button { selectedTab = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? colors.accent : colors.secondary)
                        .lineLimit(1)
                        .frame(width: tab == .agent ? 48 : 43, height: 24)
                        .background(isSelected ? colors.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isSelected)
                }
                .buttonStyle(DockPressStyle())
                .accessibilityLabel(tab.accessibilityTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(colors.control, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .reply: replyContent
        case .library: libraryContent
        case .agent:
            CopilotAgentPage(agent: agent, colors: colors, expandedSources: $expandedSources) { answer in
                onStageAnswer(answer)
                selectedTab = .reply
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

        var accessibilityTitle: String {
            switch self {
            case .reply: return "建议回复"
            case .library: return "资料库"
            case .agent: return "Agent"
            }
        }
    }
}

@MainActor
private struct CopilotAgentPage: View {
    @ObservedObject var agent: CopilotAgentModel
    let colors: DockColors
    @Binding var expandedSources: Set<CopilotSource.ID>
    let onStageAnswer: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canAsk: Bool { !agent.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var askTitle: String {
        if agent.errorMessage != nil { return "重试" }
        return agent.includeLibrary || agent.searchWeb ? "检索资料并询问" : "询问"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                composer
                if !agent.answer.isEmpty || !agent.sources.isEmpty {
                    Rectangle().fill(colors.line).frame(height: 1)
                }
                if !agent.answer.isEmpty { answer }
                if !agent.sources.isEmpty { sources }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { expandedSources.formIntersection(agent.sources.map(\.id)) }
        .onChange(of: agent.sources.map(\.id)) { expandedSources.formIntersection($0) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            PaletteTextEditor(
                text: $agent.question, label: "Agent 问题", fontSize: 13,
                textColor: colors.ink, accentColor: colors.accent, placeholder: "输入问题",
                placeholderColor: colors.secondary, fixedTextVerticalInset: 7, onOptimize: ask
            )
            .padding(.horizontal, 8)
            .frame(height: 64)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(colors.line).allowsHitTesting(false) }

            HStack(spacing: 12) {
                Toggle("使用本地资料", isOn: $agent.includeLibrary)
                Toggle("联网搜索", isOn: $agent.searchWeb)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.system(size: 12))
            .disabled(agent.isWorking)

            Text("问题与相关资料的标题、链接和摘录会发送给 DeepSeek。原文件保留在本机。")
                .font(.system(size: 11))
                .foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    if agent.isWorking {
                        HStack(spacing: 5) {
                            DockActivityGlyph(isBusy: true)
                            Text("正在生成回答…")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(colors.secondary)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                    }
                }
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: agent.isWorking)
                Spacer(minLength: 0)
                askButton
            }
            .frame(height: 30)

            if let error = agent.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: agent.errorMessage)
    }

    private var askButton: some View {
        Button {
            if agent.isWorking { agent.cancel() } else { ask() }
        } label: {
            Text(agent.isWorking ? "取消" : askTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(agent.isWorking || !canAsk ? colors.secondary : .white)
                .padding(.horizontal, 12)
                .frame(minWidth: 56)
                .frame(height: 30)
                .background(canAsk && !agent.isWorking ? colors.action : colors.control, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(DockPressStyle())
        .disabled(!agent.isWorking && !canAsk)
        .help(agent.isWorking ? "取消本次询问" : "⌘↩ 询问")
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                heading("回答")
                Spacer(minLength: 4)
                Button("用作回复草稿") { onStageAnswer(agent.answer) }
                    .buttonStyle(DockPressStyle())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(agent.isWorking ? colors.secondary : colors.accent)
                    .disabled(agent.isWorking)
            }
            Text(agent.answer)
                .font(.system(size: 13))
                .foregroundStyle(colors.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading("来源")
            VStack(spacing: 0) {
                ForEach(Array(agent.sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 {
                        Rectangle().fill(colors.line).frame(height: 1)
                    }
                    sourceRow(source, number: index + 1)
                }
            }
            .padding(.horizontal, 9)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sourceRow(_ source: CopilotSource, number: Int) -> some View {
        let isExpanded = expandedSources.contains(source.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if source.excerpt.isEmpty {
                    sourceTitle(source, number: number, disclosure: nil)
                } else {
                    Button {
                        if isExpanded { expandedSources.remove(source.id) } else { expandedSources.insert(source.id) }
                    } label: {
                        sourceTitle(source, number: number, disclosure: isExpanded)
                    }
                    .buttonStyle(DockPressStyle())
                    .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                }
                if let url = source.url, let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(colors.accent)
                            .frame(width: 25, height: 25)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DockPressStyle())
                    .accessibilityLabel("打开原文：\(source.title)")
                    .help("打开原文")
                }
            }
            if isExpanded && !source.excerpt.isEmpty {
                Text(source.excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                    .padding(.bottom, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceTitle(_ source: CopilotSource, number: Int, disclosure: Bool?) -> some View {
        HStack(spacing: 6) {
            Text("[\(number)]")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.secondary)
                .frame(minWidth: 20, alignment: .leading)
            Text(source.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let disclosure {
                Image(systemName: disclosure ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(colors.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .help(source.title)
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func ask() {
        guard canAsk, !agent.isWorking else { return }
        agent.ask()
    }
}

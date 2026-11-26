import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias CopilotViewState<Value> = SwiftUI.State<Value>

@MainActor
struct CopilotLibraryView: View {
    @ObservedObject var store: CopilotLibraryStore
    let appName: String
    let onStage: (CopilotMaterial) -> Void
    let onStageToDraft: (String) -> Void
    let onShowToast: (String, String) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @CopilotViewState private var query = ""
    @CopilotViewState private var selectedKind: CopilotMaterial.Kind? = nil
    @CopilotViewState private var expandedIDs: Set<UUID> = []
    @CopilotViewState private var copiedID: UUID?
    @CopilotViewState private var copyResetTask: Task<Void, Never>?
    @CopilotViewState private var editingDraft: EditorSession?
    @CopilotViewState private var deleting: CopilotMaterial?
    @CopilotViewState private var showDeletion = false
    @CopilotViewState private var error: String?
    @CopilotViewState private var isDropTargeted = false

    struct EditorSession: Identifiable {
        let id = UUID()
        let material: CopilotMaterial
        let isNew: Bool
        let initialFile: URL?
    }

    init(
        store: CopilotLibraryStore,
        appName: String = "聊天",
        onStage: @escaping (CopilotMaterial) -> Void,
        onStageToDraft: @escaping (String) -> Void = { _ in },
        onShowToast: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.store = store
        self.appName = appName
        self.onStage = onStage
        self.onStageToDraft = onStageToDraft
        self.onShowToast = onShowToast
    }

    private var theme: CopilotTheme { CopilotTheme(dark: scheme == .dark) }
    private var colors: DockColors { theme.base }

    var body: some View {
        ZStack {
            if let session = editingDraft {
                CopilotInlineMaterialEditor(
                    store: store,
                    session: session,
                    theme: theme,
                    onClose: { editingDraft = nil },
                    onSaved: { title in
                        editingDraft = nil
                        onShowToast("已保存「\(title)」", "checkmark.circle.fill")
                    }
                )
                .id(session.id)
                .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
            } else {
                browserView
                    .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
            }
        }
        .animation(DockMotion.page(reduceMotion: reduceMotion), value: editingDraft?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background)
        .foregroundStyle(colors.ink)
        .tint(colors.action)
        .onDisappear { copyResetTask?.cancel() }
        .alert("删除素材？", isPresented: $showDeletion, presenting: deleting) { material in
            Button("删除", role: .destructive) { delete(material.id) }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { material in
            Text("将从本机素材库删除「\(material.title)」。")
        }
    }

    private var browserView: some View {
        let results = store.search(query, kind: selectedKind, limit: max(store.materials.count, 1))
        return VStack(alignment: .leading, spacing: 9) {
            // Search & action bar
            HStack(spacing: 6) {
                searchField
                Button(action: addFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.secondary)
                        .frame(width: 32, height: 32)
                        .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.cardBorder, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                }
                .buttonStyle(DockPressStyle())
                .help("从剪贴板新建素材")
                .accessibilityLabel("从剪贴板新建素材")

                Button(action: addMaterial) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("新增")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(colors.action, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(DockPressStyle())
                .help("新增素材")
            }

            // Kind filter pills
            filterBar

            if let message = error ?? store.storageError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if error != nil {
                        Button { error = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(colors.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityAddTraits(.updatesFrequently)
            }

            // Results list or empty state
            if results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { material in
                            materialCard(material)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.accentSoft.opacity(0.92))
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(colors.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(colors.accent)
                Text("松开添加到资料库")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(colors.ink)
                Text("支持图片、视频、链接或文案")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondary)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(colors.secondary)
                .accessibilityHidden(true)
            TextField("搜索文案、链接或标签", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .accessibilityLabel("搜索素材")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondary)
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                filterChip(title: "全部", count: store.materials.count, selected: selectedKind == nil) {
                    selectedKind = nil
                }
                ForEach(CopilotMaterial.Kind.allCases, id: \.self) { kind in
                    filterChip(
                        title: kind.title,
                        count: store.count(of: kind),
                        selected: selectedKind == kind
                    ) {
                        selectedKind = selectedKind == kind ? nil : kind
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func filterChip(title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        let shape = Capsule(style: .continuous)
        return Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(selected ? colors.accent : colors.secondary)
                }
            }
            .foregroundStyle(selected ? colors.accent : colors.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(selected ? theme.accentSoft : colors.control, in: shape)
            .overlay {
                shape.strokeBorder(
                    selected ? colors.accent.opacity(theme.dark ? 0.35 : 0.25) : theme.cardBorder,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
        }
        .buttonStyle(DockPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.materials.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(colors.secondary.opacity(0.8))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(store.materials.isEmpty ? "还没有自定义资料" : "没有匹配的素材")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.ink)
                Text(store.materials.isEmpty
                     ? "存放常用话术、H5 链接、产品图或视频，\n也支持直接拖入文件。"
                     : "试试换个关键词，或切换上方分类筛选。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(colors.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            if store.materials.isEmpty {
                HStack(spacing: 8) {
                    emptyStateButton("新建素材", symbol: "plus", primary: true, action: addMaterial)
                    emptyStateButton("从剪贴板导入", symbol: "doc.on.clipboard", primary: false, action: addFromClipboard)
                }
                .frame(maxWidth: 244)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11.5, weight: primary ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .foregroundStyle(primary ? .white : colors.ink)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(primary ? colors.action : theme.composerSurface, in: shape)
            .overlay { shape.strokeBorder(primary ? .clear : theme.cardBorder).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(DockPressStyle())
    }

    private func materialCard(_ material: CopilotMaterial) -> some View {
        let isMedia = material.kind.importType != nil
        let attachmentURL = isMedia ? store.attachmentURL(for: material) : nil
        let hasAttachment = attachmentURL != nil
        let missingFile = isMedia && !hasAttachment
        let isExpanded = expandedIDs.contains(material.id)
        let isCopied = copiedID == material.id

        return VStack(alignment: .leading, spacing: 8) {
            // Identity header row
            HStack(alignment: .top, spacing: 9) {
                if let url = attachmentURL {
                    materialIdentity(material, attachmentURL: url, missingFile: false)
                        .onDrag {
                            NSItemProvider(contentsOf: url) ?? NSItemProvider()
                        }
                        .help("也可拖到\(appName)聊天输入框")
                } else {
                    materialIdentity(material, attachmentURL: nil, missingFile: missingFile)
                        .onTapGesture {
                            guard !isMedia else { return }
                            toggleExpanded(material.id)
                        }
                }

                // Pin & more menu
                HStack(spacing: 2) {
                    CopilotIconHoverButton(
                        symbol: material.isPinned ? "pin.fill" : "pin",
                        theme: theme,
                        tint: material.isPinned ? colors.accent : colors.secondary,
                        size: 24,
                        iconSize: 10.5,
                        helpText: material.isPinned ? "取消置顶" : "置顶素材",
                        isActive: material.isPinned
                    ) {
                        togglePin(material.id)
                    }

                    Menu {
                        Button {
                            editingDraft = EditorSession(material: material, isNew: false, initialFile: nil)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button {
                            togglePin(material.id)
                        } label: {
                            Label(material.isPinned ? "取消置顶" : "置顶", systemImage: material.isPinned ? "pin.slash" : "pin")
                        }
                        if material.kind == .link, let url = DeepSeekPromptAPI.publicWebURL(material.body) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("在浏览器打开", systemImage: "arrow.up.right.square")
                            }
                        }
                        if let url = attachmentURL {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Label("在访达中显示", systemImage: "folder")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleting = material
                            showDeletion = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(colors.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(colors.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(material.title)的更多操作")
                }
            }

            // Optional tags
            if !material.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(material.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(colors.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.cardSubtle, in: Capsule(style: .continuous))
                        }
                    }
                }
            }

            // Expandable full body preview for text & link
            if isExpanded && !isMedia {
                Text(material.body)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.cardSubtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            // Action strip
            HStack(spacing: 6) {
                Button { onStage(material) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("放入\(appName)")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(missingFile ? colors.secondary : colors.accent)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        missingFile ? colors.control : theme.accentSoft,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(DockPressStyle())
                .disabled(missingFile)
                .accessibilityLabel("将\(material.title)放入\(appName)聊天草稿")
                .help("直接放入当前聊天输入框供核对")

                if !isMedia {
                    Button { onStageToDraft(material.body) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.left")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("填入草稿")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(colors.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(colors.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(DockPressStyle())
                    .help("填入回复草稿继续修改或润色")
                } else if hasAttachment {
                    Text("可拖入聊天")
                        .font(.system(size: 10.5))
                        .foregroundStyle(colors.secondary)
                }

                Spacer(minLength: 2)

                if !isMedia {
                    CopilotIconHoverButton(
                        symbol: isExpanded ? "chevron.up" : "chevron.down",
                        theme: theme,
                        size: 24,
                        iconSize: 9.5,
                        helpText: isExpanded ? "收起内容" : "展开全文"
                    ) {
                        toggleExpanded(material.id)
                    }

                    CopilotIconHoverButton(
                        symbol: isCopied ? "checkmark" : "doc.on.doc",
                        theme: theme,
                        tint: isCopied ? theme.success : nil,
                        size: 24,
                        iconSize: 10.5,
                        helpText: isCopied ? "已复制" : "复制内容"
                    ) {
                        copyMaterial(material)
                    }
                }
            }
        }
        .padding(10)
        .modifier(CopilotHoverRow(theme: theme, cornerRadius: 10))
    }

    private func materialIdentity(_ material: CopilotMaterial, attachmentURL: URL?, missingFile: Bool) -> some View {
        let tint = theme.kindTint(material.kind)
        return HStack(alignment: .center, spacing: 9) {
            if let attachmentURL {
                CopilotMaterialThumbnail(url: attachmentURL, kind: material.kind, theme: theme)
                    .frame(width: 38, height: 38)
            } else {
                Image(systemName: material.kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(missingFile ? colors.warning : tint.foreground)
                    .frame(width: 38, height: 38)
                    .background(
                        missingFile ? theme.warningSoft : tint.background,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: material.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(colors.ink)
                        .lineLimit(1)
                }
                Text(subtitleText(for: material, missingFile: missingFile))
                    .font(.system(size: 11))
                    .foregroundStyle(missingFile ? colors.warning : colors.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitleText(for material: CopilotMaterial, missingFile: Bool) -> String {
        if missingFile { return "附件不可用，请重新导入" }
        switch material.kind {
        case .link:
            return "链接 · \(material.linkHost ?? preview(material.body))"
        case .text:
            return "文案 · \(preview(material.body))"
        case .image, .video:
            return "\(material.kind.title) · \(material.body)"
        }
    }

    private func preview(_ text: String) -> String {
        text.prefix(140).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private func addMaterial() {
        let initialKind = selectedKind ?? .text
        editingDraft = EditorSession(
            material: CopilotMaterial(kind: initialKind, title: "", body: ""),
            isNew: true,
            initialFile: nil
        )
    }

    private func addFromClipboard() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first, let mediaKind = mediaKind(for: first) {
            let name = first.deletingPathExtension().lastPathComponent
            editingDraft = EditorSession(
                material: CopilotMaterial(kind: mediaKind, title: name, body: first.lastPathComponent),
                isNew: true,
                initialFile: first
            )
            return
        }
        let text = (board.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            onShowToast("剪贴板暂无可用的文案、链接或媒体文件", "info.circle")
            return
        }
        if CopilotLibraryStore.isValidWebLink(text) {
            let host = URL(string: text)?.host ?? "网页链接"
            editingDraft = EditorSession(
                material: CopilotMaterial(kind: .link, title: host, body: text),
                isNew: true,
                initialFile: nil
            )
        } else {
            let firstLine = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            let suggestedTitle = String(firstLine.prefix(20))
            editingDraft = EditorSession(
                material: CopilotMaterial(kind: .text, title: suggestedTitle, body: text),
                isNew: true,
                initialFile: nil
            )
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in
                    self.openEditorForDroppedURL(url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in
                    self.openEditorForDroppedURL(url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String?
                if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = item as? String
                }
                guard let text else { return }
                Task { @MainActor in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if CopilotLibraryStore.isValidWebLink(trimmed) {
                        let host = URL(string: trimmed)?.host ?? "网页链接"
                        self.editingDraft = EditorSession(
                            material: CopilotMaterial(kind: .link, title: host, body: trimmed),
                            isNew: true,
                            initialFile: nil
                        )
                    } else {
                        let title = String((trimmed.components(separatedBy: .newlines).first ?? "").prefix(20))
                        self.editingDraft = EditorSession(
                            material: CopilotMaterial(kind: .text, title: title, body: trimmed),
                            isNew: true,
                            initialFile: nil
                        )
                    }
                }
            }
            return true
        }
        return false
    }

    private func openEditorForDroppedURL(_ url: URL) {
        if url.isFileURL, let kind = mediaKind(for: url) {
            let name = url.deletingPathExtension().lastPathComponent
            editingDraft = EditorSession(
                material: CopilotMaterial(kind: kind, title: name, body: url.lastPathComponent),
                isNew: true,
                initialFile: url
            )
        } else if CopilotLibraryStore.isValidWebLink(url.absoluteString) {
            let host = url.host ?? "网页链接"
            editingDraft = EditorSession(
                material: CopilotMaterial(kind: .link, title: host, body: url.absoluteString),
                isNew: true,
                initialFile: nil
            )
        } else {
            error = "仅支持拖入图片、视频、http/https 链接或纯文本。"
        }
    }

    private func mediaKind(for fileURL: URL) -> CopilotMaterial.Kind? {
        guard fileURL.isFileURL,
              let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: fileURL.pathExtension) else { return nil }
        if contentType.conforms(to: .image) { return .image }
        if contentType.conforms(to: .movie) { return .video }
        return nil
    }

    private func togglePin(_ id: UUID) {
        do {
            try store.togglePin(id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copyMaterial(_ material: CopilotMaterial) {
        CopilotPasteboard.copy(material.body)
        copiedID = material.id
        onShowToast("已复制「\(material.title)」", "checkmark.circle.fill")
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            if copiedID == material.id { copiedID = nil }
        }
    }

    private func delete(_ id: UUID) {
        defer { deleting = nil }
        do {
            try store.remove(id)
            expandedIDs.remove(id)
            error = nil
            onShowToast("已删除素材", "trash")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private struct CopilotMaterialThumbnail: View {
    let url: URL
    let kind: CopilotMaterial.Kind
    let theme: CopilotTheme

    @CopilotViewState private var image: NSImage?

    var body: some View {
        let tint = theme.kindTint(kind)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                if kind == .video {
                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 18, height: 18)
                    Image(systemName: "play.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 0.5)
                }
            } else {
                tint.background
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint.foreground)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(theme.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: url) {
            image = await CopilotThumbnailCache.shared.thumbnail(for: url, kind: kind, maxPixelSize: 120)
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private struct CopilotInlineMaterialEditor: View {
    @ObservedObject var store: CopilotLibraryStore
    let session: CopilotLibraryView.EditorSession
    let theme: CopilotTheme
    let onClose: () -> Void
    let onSaved: (String) -> Void

    @CopilotViewState private var draft: CopilotMaterial
    @CopilotViewState private var tagsText: String
    @CopilotViewState private var selectedFile: URL?
    @CopilotViewState private var importing = false
    @CopilotViewState private var saving = false
    @CopilotViewState private var error: String?

    init(
        store: CopilotLibraryStore,
        session: CopilotLibraryView.EditorSession,
        theme: CopilotTheme,
        onClose: @escaping () -> Void,
        onSaved: @escaping (String) -> Void
    ) {
        self.store = store
        self.session = session
        self.theme = theme
        self.onClose = onClose
        self.onSaved = onSaved
        _draft = State(initialValue: session.material)
        _tagsText = State(initialValue: session.material.tags.joined(separator: ", "))
        _selectedFile = State(initialValue: session.initialFile)
    }

    private var colors: DockColors { theme.base }
    private var canSave: Bool {
        !saving && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Editor top bar
            HStack(spacing: 8) {
                Button(action: onClose) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .background(colors.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(DockPressStyle())
                .disabled(saving)

                Text(session.isNew ? "新增素材" : "编辑素材")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.ink)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 4)

                CopilotIconHoverButton(
                    symbol: draft.isPinned ? "pin.fill" : "pin",
                    theme: theme,
                    tint: draft.isPinned ? colors.accent : colors.secondary,
                    size: 26,
                    iconSize: 11,
                    helpText: draft.isPinned ? "已置顶" : "保存后置顶",
                    isActive: draft.isPinned
                ) {
                    draft.isPinned.toggle()
                }
                .disabled(saving)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.headerSurface)

            Rectangle().fill(colors.line).frame(height: 1)

            // Editor form
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.isNew {
                        VStack(alignment: .leading, spacing: 6) {
                            CopilotSectionTitle(title: "素材类型", theme: theme)
                            HStack(spacing: 5) {
                                ForEach(CopilotMaterial.Kind.allCases, id: \.self) { kind in
                                    let active = draft.kind == kind
                                    Button {
                                        guard draft.kind != kind else { return }
                                        draft.kind = kind
                                        selectedFile = nil
                                        draft.body = ""
                                        error = nil
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: kind.symbol)
                                                .font(.system(size: 10.5, weight: .semibold))
                                            Text(kind.title)
                                                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                        }
                                        .foregroundStyle(active ? colors.accent : colors.secondary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 28)
                                        .background(
                                            active ? theme.accentSoft : colors.control,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(active ? colors.accent.opacity(0.32) : theme.cardBorder, lineWidth: 1)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .buttonStyle(DockPressStyle())
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        CopilotSectionTitle(title: "名称", theme: theme)
                        TextField("例如：产品简介、预约链接、价目图", text: $draft.title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 9)
                            .frame(height: 32)
                            .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(theme.cardBorder, lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        CopilotSectionTitle(title: "标签（选填）", theme: theme)
                        TextField("逗号分隔，如：售前, 报价", text: $tagsText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(theme.cardBorder, lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                    }

                    contentSection

                    if let error {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text(error)
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(colors.warning)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(12)
            }
            .disabled(saving)

            Rectangle().fill(colors.line).frame(height: 1)

            // Footer save bar
            HStack(spacing: 8) {
                if saving {
                    HStack(spacing: 5) {
                        DockActivityGlyph(isBusy: true)
                        Text("正在保存…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(colors.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button("取消") { onClose() }
                    .buttonStyle(DockPressStyle())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .background(colors.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .disabled(saving)

                Button(action: save) {
                    Text(saving ? "保存中…" : "保存素材")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(canSave ? .white : colors.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 29)
                        .background(canSave ? colors.action : colors.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(DockPressStyle())
                .disabled(!canSave)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.headerSurface)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [draft.kind.importType ?? .data], onCompletion: receiveFile)
    }

    @ViewBuilder
    private var contentSection: some View {
        switch draft.kind {
        case .text:
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    CopilotSectionTitle(title: "文案内容", theme: theme)
                    Spacer()
                    Text("\(draft.body.count) 字")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(colors.secondary)
                }
                PaletteTextEditor(
                    text: $draft.body,
                    label: "文案内容",
                    fontSize: 12.5,
                    textColor: colors.ink,
                    accentColor: colors.accent,
                    placeholder: "输入常用话术、公司介绍或回复模板…",
                    placeholderColor: colors.secondary,
                    fixedTextVerticalInset: 7
                )
                .padding(.horizontal, 7)
                .frame(height: 150)
                .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        case .link:
            VStack(alignment: .leading, spacing: 5) {
                CopilotSectionTitle(title: "链接地址", theme: theme)
                TextField("https://example.com", text: $draft.body)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .autocorrectionDisabled()
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(theme.composerSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
            }
        case .image, .video:
            let previewURL = selectedFile ?? store.attachmentURL(for: draft)
            VStack(alignment: .leading, spacing: 8) {
                CopilotSectionTitle(title: draft.kind == .image ? "图片文件" : "视频文件", theme: theme)
                HStack(spacing: 10) {
                    if let previewURL {
                        CopilotMaterialThumbnail(url: previewURL, kind: draft.kind, theme: theme)
                            .frame(width: 48, height: 48)
                    } else {
                        let tint = theme.kindTint(draft.kind)
                        Image(systemName: draft.kind.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(tint.foreground)
                            .frame(width: 48, height: 48)
                            .background(tint.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedFile?.lastPathComponent ?? (draft.body.isEmpty ? "尚未选择文件" : draft.body))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(colors.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(draft.body.isEmpty && selectedFile == nil ? "选择文件…" : "更换文件…") {
                            importing = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .copilotCard(theme, cornerRadius: 9, subtle: true)
            }
        }
    }

    private func receiveFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let file):
            selectedFile = file
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.title = file.deletingPathExtension().lastPathComponent
            }
            error = nil
        case .failure(let failure):
            error = (failure as? CocoaError)?.code == .userCancelled ? nil : "无法打开所选文件。"
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        var toSave = draft
        toSave.tags = CopilotLibraryStore.parseTags(tagsText)
        Task {
            defer { saving = false }
            do {
                try await store.save(toSave, importing: selectedFile)
                onSaved(toSave.title.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

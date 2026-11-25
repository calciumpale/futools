import SwiftUI
import UniformTypeIdentifiers

private typealias CopilotViewState<Value> = SwiftUI.State<Value>

@MainActor
struct CopilotLibraryView: View {
    @ObservedObject var store: CopilotLibraryStore
    let onStage: (CopilotMaterial) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @CopilotViewState private var query = ""
    @CopilotViewState private var editing: CopilotMaterial?
    @CopilotViewState private var deleting: CopilotMaterial?
    @CopilotViewState private var showDeletion = false
    @CopilotViewState private var error: String?

    init(store: CopilotLibraryStore, onStage: @escaping (CopilotMaterial) -> Void) {
        self.store = store
        self.onStage = onStage
    }

    private var colors: DockColors { DockColors(dark: scheme == .dark) }

    var body: some View {
        let results = store.search(query, limit: store.materials.count)
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            if let message = error ?? store.storageError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(colors.warning)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if results.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { material in
                            materialRow(material)
                            Rectangle().fill(colors.line).frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background)
        .foregroundStyle(colors.ink)
        .tint(colors.action)
        .sheet(item: $editing) { entry in
            CopilotMaterialEditor(store: store, material: entry)
        }
        .alert("删除素材？", isPresented: $showDeletion, presenting: deleting) { material in
            Button("删除", role: .destructive) { delete(material.id) }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { material in
            Text("将从本机素材库删除「\(material.title)」。")
        }
    }

    private var header: some View {
        HStack {
            Text("资料库")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: addMaterial) {
                Label("新增", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(colors.secondary)
                .accessibilityHidden(true)
            TextField("搜索文案、链接或素材", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索素材")
            Button { query = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(colors.secondary)
                    .frame(width: 17, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清空搜索")
            .accessibilityHidden(query.isEmpty)
            .disabled(query.isEmpty)
            .opacity(query.isEmpty ? 0 : 1)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: query.isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .modifier(CopilotMaterialHover(colors: colors))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.line).allowsHitTesting(false))
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: store.materials.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 23, weight: .light))
                .accessibilityHidden(true)
            Text(store.materials.isEmpty ? "素材库为空" : "没有匹配的素材")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(colors.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func materialRow(_ material: CopilotMaterial) -> some View {
        let media = material.kind.importType != nil
        let hasAttachment = media && store.attachmentURL(for: material) != nil
        let missingFile = media && !hasAttachment
        return HStack(spacing: 9) {
            if hasAttachment {
                materialIdentity(material, missingFile: false)
                    .onDrag {
                        guard let url = store.attachmentURL(for: material) else { return NSItemProvider() }
                        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                    }
                    .help("也可拖到聊天输入框")
                    .accessibilityHint("也可拖到聊天输入框")
            } else {
                materialIdentity(material, missingFile: missingFile)
            }
            Button("放入草稿") { onStage(material) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(missingFile)
                .accessibilityLabel("将\(material.title)放入聊天草稿")
                .help("放入当前聊天草稿供核对")
            Menu {
                Button("编辑") { editing = material }
                Button("删除", role: .destructive) {
                    deleting = material
                    showDeletion = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(material.title)的更多操作")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func materialIdentity(_ material: CopilotMaterial, missingFile: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: material.kind.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(colors.accent)
                .frame(width: 30, height: 30)
                .background(colors.selection, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: material.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(missingFile ? "文件不可用" : "\(material.kind.title) · \(preview(material.body))")
                    .font(.system(size: 11))
                    .foregroundStyle(missingFile ? colors.warning : colors.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func preview(_ text: String) -> String {
        text.prefix(140).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func addMaterial() {
        editing = CopilotMaterial(kind: .text, title: "", body: "")
    }

    private func delete(_ id: UUID) {
        defer { deleting = nil }
        do {
            try store.remove(id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CopilotMaterialHover: ViewModifier {
    let colors: DockColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @CopilotViewState private var hovered = false

    func body(content: Content) -> some View {
        content.background(hovered ? colors.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: hovered)
    }
}

@MainActor
private struct CopilotMaterialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var store: CopilotLibraryStore
    @CopilotViewState private var draft: CopilotMaterial
    @CopilotViewState private var selectedFile: URL?
    @CopilotViewState private var importing = false
    @CopilotViewState private var saving = false
    @CopilotViewState private var error: String?
    private let isNew: Bool

    init(store: CopilotLibraryStore, material: CopilotMaterial) {
        self.store = store
        _draft = State(initialValue: material)
        isNew = !store.materials.contains { $0.id == material.id }
    }

    private var colors: DockColors { DockColors(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(isNew ? "新增素材" : "编辑素材")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if isNew {
                Picker("类型", selection: $draft.kind) {
                    ForEach(CopilotMaterial.Kind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
            TextField("名称", text: $draft.title, prompt: Text("例如开场问候或公司介绍"))
                .textFieldStyle(.roundedBorder)
            contentField
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(colors.warning)
            }
            HStack(spacing: 9) {
                Spacer()
                DockActivityGlyph(isBusy: saving)
                    .accessibilityLabel("正在保存素材")
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "保存中…" : "保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
        .foregroundStyle(colors.ink)
        .background(colors.background)
        .tint(colors.action)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .fileImporter(isPresented: $importing, allowedContentTypes: [draft.kind.importType ?? .data], onCompletion: receiveFile)
        .onChange(of: draft.kind) { _ in
            selectedFile = nil
            draft.body = ""
            error = nil
        }
    }

    @ViewBuilder
    private var contentField: some View {
        switch draft.kind {
        case .text:
            VStack(alignment: .leading, spacing: 5) {
                Text("文案").font(.callout).foregroundStyle(colors.secondary)
                TextEditor(text: $draft.body)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(height: 126)
                    .background(colors.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line).allowsHitTesting(false))
                    .accessibilityLabel("文案内容")
            }
        case .link:
            TextField("链接地址", text: $draft.body, prompt: Text("https://"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        case .image, .video:
            HStack(spacing: 9) {
                Label(selectedFile?.lastPathComponent ?? (draft.body.isEmpty ? "尚未选择文件" : draft.body), systemImage: draft.kind.symbol)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(colors.secondary)
                Spacer(minLength: 5)
                Button(draft.body.isEmpty && selectedFile == nil ? "选择文件" : "更换文件") { importing = true }
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
        Task {
            defer { saving = false }
            do {
                try await store.save(draft, importing: selectedFile)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

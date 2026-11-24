import AppKit
import SwiftUI

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    private let model: PaletteModel
    private var window: PaletteWindow?
    private var target: NSRunningApplication?

    var onInsert: ((String, NSRunningApplication?) -> Void)?
    var onNavigate: ((LibraryDestination) -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    init(store: PromptStore, optimizer: PromptOptimizer) {
        model = PaletteModel(store: store, optimizer: optimizer)
        super.init()
        model.performInsert = { [weak self] text in self?.insert(text) }
        model.navigate = { [weak self] destination in self?.onNavigate?(destination) }
        model.cancel = { [weak self] in self?.dismiss() }
        model.focusSearch = { [weak self] in self?.window?.focusSearch() }
        model.handleSearchCommand = { [weak self] command in
            self?.handleSearchCommand(command) ?? false
        }
    }

    func show(target: NSRunningApplication?) {
        guard let screen = screenUnderCursor() else { return }
        self.target = target
        model.prepare(for: target)
        let window = self.window ?? makeWindow()
        self.window = window

        let area = screen.visibleFrame
        let size = window.frame.size
        let top = min(max((area.height - size.height) * 0.26, 12), 150)
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - top))
        window.makeKeyAndOrderFront(nil)
        window.focusSearch()
        window.invalidateShadow()
    }

    func dismiss() {
        window?.pendingEnter = nil
        window?.orderOut(nil)
        model.optimizer.cancel()
        target = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Allow the original key-window transition to finish before ordering the panel out.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.window?.isKeyWindow == false else { return }
            self.dismiss()
        }
    }

    private func insert(_ text: String) {
        let originalTarget = target
        dismiss()
        onInsert?(text, originalTarget)
    }

    private func makeWindow() -> PaletteWindow {
        let window = PaletteWindow(
            contentRect: NSRect(x: 0, y: 0, width: PaletteView.width, height: PaletteView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Prompt Dock 命令面板"
        window.isFloatingPanel = true
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isMovable = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.delegate = self
        window.onCancel = { [weak self] in self?.dismiss() }
        window.onConfirm = { [weak self] in self?.model.confirmSelection() }
        window.contentView = NSHostingView(rootView: PaletteView(
            model: model, store: model.store, optimizer: model.optimizer
        ))
        return window
    }

    private func handleSearchCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)):
            guard model.navigatesMatches else { return false }
            model.moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard model.navigatesMatches else { return false }
            model.moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            // Keep focus until key-up so a held Return cannot repeat into the target app.
            if let event = NSApp.currentEvent, event.type == .keyDown,
               event.keyCode == 36 || event.keyCode == 76 {
                window?.pendingEnter = event.keyCode
            } else {
                model.confirmSelection()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}

@MainActor
final class PaletteWindow: NSPanel {
    weak var searchField: NSTextView?
    var pendingEnter: UInt16?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func focusSearch() {
        if let searchField { makeFirstResponder(searchField) }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyUp, event.keyCode == pendingEnter {
            pendingEnter = nil
            onConfirm?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
private final class PaletteModel: ObservableObject {
    let store: PromptStore
    let optimizer: PromptOptimizer
    @Published private(set) var selectedID: UUID?
    @Published private(set) var targetName: String?
    @Published private(set) var targetIcon: NSImage?
    @Published private(set) var hasPermission = false

    var performInsert: ((String) -> Void)?
    var navigate: ((LibraryDestination) -> Void)?
    var cancel: (() -> Void)?
    var focusSearch: (() -> Void)?
    var handleSearchCommand: ((Selector) -> Bool)?

    init(store: PromptStore, optimizer: PromptOptimizer) {
        self.store = store
        self.optimizer = optimizer
    }

    var matches: [Prompt] { store.matching(optimizer.draft) }
    var selectedPrompt: Prompt? { matches.first { $0.id == selectedID } }
    var navigatesMatches: Bool {
        !optimizer.draft.contains(where: \.isNewline) && !matches.isEmpty
    }
    var canOptimize: Bool {
        !optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var insertionText: String? {
        guard !optimizer.isOptimizing else { return nil }
        if let selectedPrompt { return selectedPrompt.body }
        let text = optimizer.hasResult ? optimizer.result : optimizer.draft
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    func prepare(for target: NSRunningApplication?) {
        targetName = target.map { $0.localizedName ?? "当前应用" }
        targetIcon = target?.icon
        hasPermission = PasteService.hasPermission
        optimizer.reset()
        selectedID = matches.first?.id
    }

    func setDraft(_ value: String) {
        guard optimizer.draft != value else { return }
        optimizer.draft = value
        optimizer.clearResult()
        selectedID = matches.first?.id
    }

    func optimize() {
        guard canOptimize, !optimizer.isOptimizing else { return }
        selectedID = nil
        optimizer.optimize()
    }

    func select(_ prompt: Prompt) { selectedID = prompt.id }
    func chooseResult() { selectedID = nil }

    func moveSelection(by delta: Int) {
        let prompts = matches
        guard !prompts.isEmpty else { return }
        let current = prompts.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : prompts.count)
        let next = min(max(current + delta, 0), prompts.count - 1)
        selectedID = prompts[next].id
    }

    func confirmSelection() {
        if let insertionText { performInsert?(insertionText) }
    }
}

private struct PaletteView: View {
    static let width: CGFloat = 678
    static let height: CGFloat = 487
    @ObservedObject var model: PaletteModel
    @ObservedObject var store: PromptStore
    @ObservedObject var optimizer: PromptOptimizer
    @Environment(\.colorScheme) private var scheme

    private var colors: PaletteColors { PaletteColors(dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            separator
            HStack(spacing: 0) {
                results.frame(width: 308)
                Rectangle().fill(colors.line).frame(width: 1)
                preview
            }
            .frame(maxHeight: .infinity)
            if let error = optimizer.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.warning)
                    .lineLimit(2)
                    .help(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 7)
            }
            separator
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(colors.ink)
        .background(colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .strokeBorder(colors.outline, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var separator: some View { Rectangle().fill(colors.line).frame(height: 1) }

    private var searchBar: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(colors.accent)
                .frame(height: PaletteTextEditor.searchMinimumHeight)
                .accessibilityHidden(true)
            PaletteTextEditor(
                text: Binding(get: { optimizer.draft }, set: model.setDraft),
                label: "搜索或输入提示词",
                fontSize: 18,
                textColor: colors.ink,
                accentColor: colors.accent,
                placeholder: "搜索或输入",
                isSearchEditor: true,
                onCommand: { model.handleSearchCommand?($0) ?? false },
                onOptimize: model.optimize
            )
            .frame(maxWidth: .infinity)
            if !optimizer.draft.isEmpty {
                Button {
                    model.setDraft("")
                    model.focusSearch?()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(colors.dim)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .frame(height: PaletteTextEditor.searchMinimumHeight)
                .accessibilityLabel("清空输入")
            }
            Button { model.navigate?(.library) } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.dim)
                    .frame(width: 31, height: 29)
                    .background(colors.control, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .frame(height: PaletteTextEditor.searchMinimumHeight)
            .help("管理提示词")
            .accessibilityLabel("管理提示词")
            closeButton.frame(height: PaletteTextEditor.searchMinimumHeight)
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 10)
    }

    private var closeButton: some View {
        Button { model.cancel?() } label: {
            KeyCap(label: "esc", colors: colors).frame(height: 29)
        }
        .buttonStyle(.plain)
        .help("关闭面板")
        .accessibilityLabel("关闭面板")
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(optimizer.draft.isEmpty ? "提示词" : "搜索结果")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.matches.count) 条")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .accessibilityLabel("\(model.matches.count) 条提示词")
            }
            .foregroundStyle(colors.dim)
            .padding(.horizontal, 10)

            if model.matches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.prompts.isEmpty ? "还没有提示词" : "没有匹配的提示词")
                        .font(.system(size: 14, weight: .semibold))
                    if store.prompts.isEmpty {
                        Button("新建提示词") { model.navigate?(.new) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(colors.accent)
                    } else {
                        Text("试试标题、分类或内容里的其他关键词。")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.dim)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.matches) { prompt in
                                promptRow(prompt).id(prompt.id)
                            }
                        }
                    }
                    .onChange(of: model.selectedID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 13)
    }

    private func promptRow(_ prompt: Prompt) -> some View {
        let selected = model.selectedID == prompt.id
        return Button {
            model.select(prompt)
            model.focusSearch?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: prompt.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? colors.accent : colors.dim)
                    .frame(width: 33, height: 33)
                    .background(selected ? colors.iconSelected : colors.control, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    if !prompt.category.isEmpty {
                        Text(prompt.category).font(.system(size: 11)).foregroundStyle(colors.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(colors.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 51)
            .contentShape(Rectangle())
            .background(selected ? colors.selection : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("编辑提示词") { model.navigate?(.prompt(prompt.id)) }
        }
    }

    private var preview: some View {
        Group {
            if optimizer.hasResult {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Text("优化结果")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if model.selectedID != nil {
                            Button("选用结果", action: model.chooseResult)
                                .buttonStyle(.plain)
                                .foregroundStyle(colors.accent)
                        }
                        Button("存为提示词") { model.navigate?(.newWithBody(optimizer.result)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(colors.accent)
                            .disabled(!canSaveResult)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(colors.dim)
                    PaletteTextEditor(
                        text: $optimizer.result,
                        label: "优化结果正文",
                        fontSize: 14,
                        textColor: colors.body,
                        accentColor: colors.accent,
                        onFocus: model.chooseResult
                    )
                    .frame(maxHeight: .infinity)
                }
                .padding(15)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.preview)
    }

    private var canSaveResult: Bool {
        !optimizer.isOptimizing && !optimizer.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var insertTitle: String {
        if model.hasPermission, let target = model.targetName { return "填入 \(target)" }
        return "复制"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            KeyCap(label: "↑", colors: colors)
            KeyCap(label: "↓", colors: colors)
            Text("切换").foregroundStyle(colors.dim)
            KeyCap(label: "⇧↩", colors: colors).padding(.leading, 5)
            Text("换行").foregroundStyle(colors.dim)
            Spacer(minLength: 12)
            Button {
                if optimizer.isOptimizing {
                    optimizer.cancel()
                } else {
                    model.optimize()
                }
            } label: {
                HStack(spacing: 6) {
                    if optimizer.isOptimizing {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    } else {
                        Image(systemName: "sparkles").accessibilityHidden(true)
                    }
                    Text(optimizer.isOptimizing ? "取消优化" : "优化提示词")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12))
                .foregroundStyle(colors.accent)
                .padding(.horizontal, 11)
                .frame(height: 29)
                .background(colors.selection, in: RoundedRectangle(cornerRadius: 7))
                .opacity(model.canOptimize ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!model.canOptimize)
            .accessibilityLabel(optimizer.isOptimizing ? "取消优化" : "优化提示词")
            .help("⌘↩ 优化")

            Button { model.confirmSelection() } label: {
                HStack(spacing: 5) {
                    if model.hasPermission, let icon = model.targetIcon {
                        Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                            .accessibilityHidden(true)
                    }
                    Text(insertTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Image(systemName: "return").font(.system(size: 10, weight: .medium))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(colors.actionText)
                .padding(.horizontal, 8)
                .frame(width: 120, height: 29)
                .background(colors.accent, in: RoundedRectangle(cornerRadius: 7))
                .opacity(model.insertionText == nil ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(model.insertionText == nil)
            .accessibilityLabel(insertTitle)
            .help(insertTitle)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .frame(height: 49)
    }

}

private struct KeyCap: View {
    let label: String
    let colors: PaletteColors

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(colors.dim)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(colors.control, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(colors.line, lineWidth: 1) }
    }
}

private struct PaletteColors {
    let dark: Bool

    var surface: Color { color(0xFAFAF6, 0x202522) }
    var preview: Color { color(0xF2F4EC, 0x1B201D) }
    var ink: Color { color(0x202723, 0xEFF4ED) }
    var body: Color { color(0x434F47, 0xC9D3CB) }
    var dim: Color { color(0x5F6E64, 0xA2B1A5) }
    var accent: Color { color(0x23634C, 0x9ADBBA) }
    var warning: Color { color(0x9E4B22, 0xFFBC89) }
    var actionText: Color { color(0xFFFFFF, 0x142C21) }
    var line: Color { color(0xE1E6DD, 0x343F37) }
    var outline: Color { color(0xD4DDD1, 0x485249) }
    var control: Color { color(0xECEFE7, 0x303A33) }
    var selection: Color { color(0xE1EDE2, 0x2B4337) }
    var iconSelected: Color { color(0xD4E7D8, 0x395744) }

    private func color(_ light: UInt32, _ darkValue: UInt32) -> Color {
        let hex = dark ? darkValue : light
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

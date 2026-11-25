import AppKit
import Carbon
import SwiftUI

// Use the property wrapper so builds also work with standalone Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum LibraryDestination {
    case library
    case prompt(UUID)
    case new
    case newWithBody(String)
    case settings
}

@MainActor
struct LibraryView: View {
    private static let navigation = Notification.Name("PromptDock.libraryNavigation")
    private static let applicationIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    @ObservedObject private var store: PromptStore
    private let shortcutRecorder: ShortcutRecorder
    private let onSaveShortcut: (HotKey) -> String?
    private let onSaveCompactShortcut: (HotKey) -> String?
    private let onSaveCopilotShortcut: (HotKey) -> String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var titleFocused: Bool
    @ViewState private var draft: Draft?
    @ViewState private var showingSettings: Bool
    @ViewState private var alert: EditorAlert?
    @ViewState private var saveMessage: String?

    init(
        store: PromptStore,
        selectedID: UUID?,
        startNew: Bool,
        newBody: String = "",
        showSettings: Bool = false,
        shortcutRecorder: ShortcutRecorder,
        onSaveShortcut: @escaping (HotKey) -> String?,
        onSaveCompactShortcut: @escaping (HotKey) -> String?,
        onSaveCopilotShortcut: @escaping (HotKey) -> String? = { _ in nil }
    ) {
        self.store = store
        self.shortcutRecorder = shortcutRecorder
        self.onSaveShortcut = onSaveShortcut
        self.onSaveCompactShortcut = onSaveCompactShortcut
        self.onSaveCopilotShortcut = onSaveCopilotShortcut
        _showingSettings = State(initialValue: showSettings)
        let selected = store.prompts.first { $0.id == selectedID } ?? store.prompts.first
        _draft = State(initialValue: startNew ? Draft.new(body: newBody) : selected.map(Draft.saved))
    }

    static func navigate(to destination: LibraryDestination) {
        NotificationCenter.default.post(name: navigation, object: destination)
    }

    private var colors: DockColors { DockColors(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(colors.line).frame(height: 1)
            storageNotice
            ZStack {
                if showingSettings {
                    LibrarySettings(store: store, colors: colors, shortcutRecorder: shortcutRecorder,
                                    onSaveShortcut: onSaveShortcut, onSaveCompactShortcut: onSaveCompactShortcut,
                                    onSaveCopilotShortcut: onSaveCopilotShortcut)
                        .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                } else {
                    libraryPage
                        .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                }
            }
            .animation(DockMotion.page(reduceMotion: reduceMotion), value: showingSettings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
        .foregroundStyle(colors.ink)
        .tint(colors.action)
        .alert(item: $alert, content: makeAlert)
        .onReceive(NotificationCenter.default.publisher(for: Self.navigation)) { notification in
            if let destination = notification.object as? LibraryDestination { navigate(destination) }
        }
        .task(id: draft?.value.id) {
            if !showingSettings, draft?.original == nil { titleFocused = draft != nil }
        }
    }

    private var libraryPage: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(colors.line).frame(width: 1)
            if let draft = Binding($draft) {
                editor(draft)
            } else {
                emptyEditor
            }
        }
    }

    private var storageNotice: some View {
        ZStack(alignment: .leading) {
            if let error = store.storageError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(colors.selection)
                    .id(error)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: store.storageError)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: Self.applicationIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 35, height: 35)
                .accessibilityHidden(true)
            Text("futools")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                tab("提示词", icon: "text.alignleft", selected: !showingSettings) { navigate(.library) }
                tab("设置", icon: "gearshape", selected: showingSettings) { navigate(.settings) }
            }
            .padding(3)
            .background(colors.control, in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 24)
        .frame(height: 62)
    }

    private func tab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? colors.accent : colors.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? colors.surface : Color.clear)
                        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: selected)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("提示词库")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !store.prompts.isEmpty {
                    Text(store.prompts.count.formatted())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colors.secondary)
                        .frame(minWidth: 30, alignment: .trailing)
                        .contentTransition(.opacity)
                        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: store.prompts.count)
                        .accessibilityLabel("共 \(store.prompts.count) 条提示词")
                }
                Button { navigate(.new) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 27, height: 25)
                        .foregroundStyle(colors.accent)
                        .background(colors.selection, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("新增提示词")
                .help("新增提示词（⌘N）")
            }
            .padding(.horizontal, 4)

            PromptListView(
                prompts: store.prompts,
                selectedID: draft?.original?.id,
                colors: colors,
                onSelect: { navigate(.prompt($0)) },
                onMove: { source, target, after in
                    store.movePrompt(source, relativeTo: target, after: after)
                }
            )
        }
        .padding(.horizontal, 13)
        .padding(.top, 15)
        .padding(.bottom, 10)
        .frame(width: 222)
        .background(colors.sidebar)
    }

    private func editor(_ draft: Binding<Draft>) -> some View {
        let entry = draft.wrappedValue
        let isNew = entry.original == nil
        return VStack(alignment: .leading, spacing: 15) {
            ZStack(alignment: .leading) {
                Text(isNew ? "新建提示词" : "编辑提示词")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .id(isNew)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
            .animation(DockMotion.transition(reduceMotion: reduceMotion), value: isNew)
            editorFields(draft)
                .id(entry.value.id)
        }
        .padding(.horizontal, 27)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func editorFields(_ draft: Binding<Draft>) -> some View {
        let entry = draft.wrappedValue
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("名称")
                    TextField("例：结构化会议纪要", text: draft.value.title)
                        .focused($titleFocused)
                        .accessibilityLabel("名称")
                        .modifier(LibraryField(colors: colors))
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("分类")
                    TextField("例：工作", text: draft.value.category)
                        .accessibilityLabel("分类")
                        .modifier(LibraryField(colors: colors))
                }
                .frame(width: 154)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("提示词正文")
                TextEditor(text: draft.value.body)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(alignment: .topLeading) {
                        if entry.value.body.isEmpty {
                            Text("输入要填入对话框的内容…")
                                .font(.system(size: 14))
                                .foregroundStyle(colors.secondary)
                                .padding(.top, 9)
                                .padding(.leading, 12)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .background(colors.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.line).allowsHitTesting(false))
                    .accessibilityLabel("提示词正文")
            }
            .frame(minHeight: 100, maxHeight: .infinity)

            HStack(spacing: 12) {
                if let original = entry.original {
                    Button { alert = .remove(original) } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(colors.secondary)
                    .help("删除此提示词")
                }
                Spacer(minLength: 0)
                editorStatus(isDirty: entry.isDirty)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!entry.canSave || !entry.isDirty)
            }
            .font(.system(size: 12))
            .frame(minHeight: 32)
        }
    }

    private func editorStatus(isDirty: Bool) -> some View {
        ZStack(alignment: .trailing) {
            if isDirty {
                Text("有未保存的修改")
                    .foregroundStyle(colors.secondary)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            } else if let saveMessage {
                Label(saveMessage, systemImage: "checkmark")
                    .foregroundStyle(colors.accent)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isDirty)
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: saveMessage)
    }

    private var emptyEditor: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(colors.accent)
                .accessibilityHidden(true)
            Text("提示词库为空")
                .font(.system(size: 18, weight: .semibold))
            Button("新增提示词") { navigate(.new) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colors.secondary)
            .accessibilityHidden(true)
    }

    private func navigate(_ destination: LibraryDestination) {
        switch destination {
        case .settings:
            showingSettings = true
        case .library:
            showingSettings = false
        case .prompt(let id) where draft?.value.id == id:
            showingSettings = false
        case .new where draft?.original == nil && draft != nil:
            showingSettings = false
        case .new, .newWithBody, .prompt:
            if draft?.isDirty == true {
                alert = .discard(destination)
            } else {
                load(destination)
            }
        }
    }

    private func load(_ destination: LibraryDestination) {
        switch destination {
        case .new:
            draft = .new()
        case .newWithBody(let text):
            draft = .new(body: text)
        case .prompt(let id):
            guard let prompt = store.prompts.first(where: { $0.id == id }) else { return }
            draft = Draft.saved(prompt)
        case .library, .settings:
            return
        }
        showingSettings = false
        saveMessage = nil
    }

    private func save() {
        guard let draft, draft.canSave, draft.isDirty else { return }
        var prompt = draft.value
        prompt.title = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.category = prompt.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.upsert(prompt) else { return }
        self.draft = Draft.saved(prompt)
        saveMessage = "已保存"
    }

    private func makeAlert(_ alert: EditorAlert) -> Alert {
        switch alert {
        case .discard(let destination):
            Alert(
                title: Text("有未保存的修改"),
                message: Text("切换后，当前修改会丢失。"),
                primaryButton: .cancel(Text("继续编辑")),
                secondaryButton: .destructive(Text("放弃修改")) { load(destination) }
            )
        case .remove(let prompt):
            Alert(
                title: Text("删除「\(prompt.title)」？"),
                message: Text("删除后无法恢复。"),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("删除")) {
                    guard store.remove(prompt.id) else { return }
                    draft = store.prompts.first.map(Draft.saved)
                    saveMessage = nil
                }
            )
        }
    }

    private struct Draft {
        var value: Prompt
        let original: Prompt?

        static func new(body: String = "") -> Self {
            Draft(value: Prompt(title: "", body: body, category: "", symbol: "text.alignleft"), original: nil)
        }
        static func saved(_ prompt: Prompt) -> Self { Draft(value: prompt, original: prompt) }

        var canSave: Bool {
            !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var isDirty: Bool {
            if let original { return value != original }
            return !value.title.isEmpty || !value.body.isEmpty || !value.category.isEmpty
        }
    }

    private enum EditorAlert: Identifiable {
        case discard(LibraryDestination)
        case remove(Prompt)

        var id: Int {
            switch self {
            case .discard: 0
            case .remove: 1
            }
        }
    }
}

@MainActor
private struct LibrarySettings: View {
    private enum ShortcutRow: Hashable {
        case command, compact, copilot

        var title: String {
            switch self {
            case .command: return "命令面板"
            case .compact: return "精简模式"
            case .copilot: return "侧边 Copilot"
            }
        }

        var defaultShortcut: HotKey {
            switch self {
            case .command: return .defaultValue
            case .compact: return .compactDefaultValue
            case .copilot: return .copilotDefaultValue
            }
        }
    }

    @ObservedObject var store: PromptStore
    let colors: DockColors
    @ObservedObject var shortcutRecorder: ShortcutRecorder
    let onSaveShortcut: (HotKey) -> String?
    let onSaveCompactShortcut: (HotKey) -> String?
    let onSaveCopilotShortcut: (HotKey) -> String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var recordingRow: ShortcutRow?
    @ViewState private var shortcutErrors: [ShortcutRow: String] = [:]
    @ViewState private var hasPermission = PasteService.hasPermission
    @AppStorage(AppAppearance.preferenceKey) private var appearance: AppAppearance = .system

    private var activeRow: ShortcutRow? { shortcutRecorder.isRecording ? recordingRow : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)

                section("全局快捷键", icon: "command") {
                    Text("用快捷键打开或关闭命令面板、精简模式和侧边 Copilot。")
                        .foregroundStyle(colors.secondary)
                    shortcutControls(.command)
                    Divider()
                    shortcutControls(.compact)
                    Divider()
                    shortcutControls(.copilot)
                }

                section("外观", icon: "circle.lefthalf.filled") {
                    appearanceControls
                }

                section("辅助功能权限", icon: "accessibility") {
                    Text("授权后，futools 可以把提示词填入其他应用已经聚焦的输入框。")
                        .foregroundStyle(colors.secondary)
                    HStack {
                        ZStack(alignment: .leading) {
                            Label(hasPermission ? "已授权" : "待授权", systemImage: hasPermission ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(hasPermission ? colors.accent : colors.secondary)
                                .id(hasPermission)
                                .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                        }
                        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: hasPermission)
                        Spacer()
                        if !hasPermission {
                            SettingsButton(title: "打开系统设置", colors: colors, action: PasteService.requestPermission)
                        }
                    }
                    .frame(minHeight: 32)
                }

                section("DeepSeek API", icon: "key") {
                    DeepSeekSettingsContent(colors: colors)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .onAppear { hasPermission = PasteService.hasPermission }
        .onChange(of: appearance) { $0.apply() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = PasteService.hasPermission
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow { shortcutRecorder.windowDidResignKey(window) }
        }
        .onDisappear { shortcutRecorder.stop() }
    }

    private func section<Content: View>(_ label: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(label, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colors.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line).allowsHitTesting(false))
    }

    private var appearanceControls: some View {
        HStack(spacing: 8) {
            appearanceControl(.system, symbol: "desktopcomputer")
            appearanceControl(.light, symbol: "sun.max")
            appearanceControl(.dark, symbol: "moon")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("外观模式")
    }

    private func appearanceControl(_ mode: AppAppearance, symbol: String) -> some View {
        let selected = appearance == mode
        return SettingsButton(
            title: mode.title, colors: colors, tone: selected ? .selected : .neutral,
            symbol: symbol, width: 100, height: 35
        ) {
            appearance = mode
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shortcutControls(_ row: ShortcutRow) -> some View {
        let shortcut = currentShortcut(for: row)
        let recording = activeRow == row
        let keyText = recording ? "按下快捷键…" : shortcut.display
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(row.title)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 84, alignment: .leading)
                ZStack {
                    Text(keyText)
                        .id(keyText)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                }
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(colors.accent)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(recording ? colors.iconSelected : colors.selection)
                }
                .accessibilityLabel(recording ? "等待录制\(row.title)快捷键" : "\(row.title)快捷键 \(shortcut.display)")
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: keyText)
                Spacer()
                SettingsButton(title: "恢复默认", colors: colors, width: 82) { applyShortcut(row.defaultShortcut, for: row) }
                    .disabled(activeRow != nil || shortcut == row.defaultShortcut)
                    .accessibilityLabel("恢复\(row.title)默认快捷键")
                SettingsButton(
                    title: recording ? "取消录制" : "录制快捷键", colors: colors,
                    tone: recording ? .neutral : .primary, width: 94
                ) {
                    toggleRecording(for: row)
                }
                .accessibilityLabel("\(recording ? "取消录制" : "录制")\(row.title)快捷键")
            }
            ZStack(alignment: .leading) {
                if let error = shortcutErrors[row] {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(colors.warning)
                        .id(error)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                } else if recording {
                    Text("按下要保存的组合键，按 Esc 取消。")
                        .foregroundStyle(colors.secondary)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: shortcutErrors[row])
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: recording)
        }
    }

    private func currentShortcut(for row: ShortcutRow) -> HotKey {
        switch row {
        case .command: return store.shortcut
        case .compact: return store.compactShortcut
        case .copilot: return store.copilotShortcut
        }
    }

    private func toggleRecording(for row: ShortcutRow) {
        shortcutErrors[row] = nil
        if activeRow == row {
            stopRecording()
        } else {
            recordingRow = row
            shortcutRecorder.start(
                onKeyDown: { capture($0, for: row) },
                onCurrentShortcut: { applyShortcut($0, for: row) }
            )
        }
    }

    private func stopRecording() {
        shortcutRecorder.stop()
        recordingRow = nil
    }

    private func capture(_ event: NSEvent, for row: ShortcutRow) {
        if event.keyCode == kVK_Escape {
            stopRecording()
            shortcutErrors[row] = nil
        } else if let shortcut = HotKey.capture(event) {
            applyShortcut(shortcut, for: row)
        } else {
            shortcutErrors[row] = "请换用组合键，例如 ⌃⌥P 或 ⌘⇧P。"
        }
    }

    private func applyShortcut(_ shortcut: HotKey, for row: ShortcutRow) {
        switch row {
        case .command: shortcutErrors[row] = onSaveShortcut(shortcut)
        case .compact: shortcutErrors[row] = onSaveCompactShortcut(shortcut)
        case .copilot: shortcutErrors[row] = onSaveCopilotShortcut(shortcut)
        }
        if shortcutErrors[row] == nil { stopRecording() }
    }
}

private struct SettingsButton: View {
    enum Tone: Equatable {
        case neutral, primary, selected
    }

    let title: String
    let colors: DockColors
    var tone: Tone = .neutral
    var symbol: String?
    var width: CGFloat?
    var height: CGFloat = 32
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let (foreground, fill, border) = style
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(title).contentTransition(.opacity)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(width: width, height: height)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(border).allowsHitTesting(false) }
            .contentShape(shape)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: tone)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isEnabled)
        }
        .buttonStyle(DockPressStyle())
    }

    private var style: (foreground: Color, fill: Color, border: Color) {
        guard isEnabled else { return (colors.secondary.opacity(0.66), colors.control.opacity(0.55), colors.line) }
        switch tone {
        case .neutral: return (colors.ink, colors.control, colors.outline)
        case .primary: return (.white, colors.action, .clear)
        case .selected: return (colors.accent, colors.selection, colors.accent.opacity(0.42))
        }
    }
}

private struct LibraryField: ViewModifier {
    let colors: DockColors

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line).allowsHitTesting(false))
    }
}

@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private weak var window: NSWindow?
    private var keyMonitor: Any?
    private var onCurrentShortcut: ((HotKey) -> Void)?

    func attach(to window: NSWindow) {
        stop()
        self.window = window
    }

    func start(onKeyDown: @escaping (NSEvent) -> Void, onCurrentShortcut: @escaping (HotKey) -> Void) {
        guard let window else { return }
        stop()
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        self.onCurrentShortcut = onCurrentShortcut
        // Capture before the responder chain and menu key equivalents handle the chord.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window || (event.window == nil && NSApp.keyWindow === window) else { return event }
            if !event.isARepeat { onKeyDown(event) }
            return nil
        }
        isRecording = true
    }

    func useCurrentShortcut(_ shortcut: HotKey) -> Bool {
        guard isRecording, let window, NSApp.keyWindow === window, NSApp.isActive,
              let onCurrentShortcut else { return false }
        onCurrentShortcut(shortcut)
        return true
    }

    func windowDidResignKey(_ window: NSWindow) {
        if self.window === window { stop() }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onCurrentShortcut = nil
        if isRecording { isRecording = false }
    }
}

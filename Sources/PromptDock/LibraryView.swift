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

    @ObservedObject private var store: PromptStore
    private let shortcutRecorder: ShortcutRecorder
    private let onSaveShortcut: (HotKey) -> String?

    @Environment(\.colorScheme) private var colorScheme
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
        onSaveShortcut: @escaping (HotKey) -> String?
    ) {
        self.store = store
        self.shortcutRecorder = shortcutRecorder
        self.onSaveShortcut = onSaveShortcut
        _showingSettings = State(initialValue: showSettings)
        let selected = store.prompts.first { $0.id == selectedID } ?? store.prompts.first
        _draft = State(initialValue: startNew ? Draft.new(body: newBody) : selected.map(Draft.saved))
    }

    static func navigate(to destination: LibraryDestination) {
        NotificationCenter.default.post(name: navigation, object: destination)
    }

    private var colors: LibraryColors { LibraryColors(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(colors.line).frame(height: 1)
            if let error = store.storageError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(colors.soft)
            }
            if showingSettings {
                LibrarySettings(store: store, colors: colors, shortcutRecorder: shortcutRecorder,
                                onSaveShortcut: onSaveShortcut)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(colors.line).frame(width: 1)
                    if let draft = Binding($draft) {
                        editor(draft)
                            .id(draft.wrappedValue.value.id)
                    } else {
                        emptyEditor
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
        .foregroundStyle(colors.ink)
        .tint(colors.accent)
        .alert(item: $alert, content: makeAlert)
        .onReceive(NotificationCenter.default.publisher(for: Self.navigation)) { notification in
            if let destination = notification.object as? LibraryDestination { navigate(destination) }
        }
        .task(id: draft?.value.id) {
            if !showingSettings, draft?.original == nil { titleFocused = draft != nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(colors.accent)
                .frame(width: 35, height: 35)
                .background(colors.soft, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            Text("Prompt Dock")
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
                .background(selected ? colors.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
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
                        .accessibilityLabel("共 \(store.prompts.count) 条提示词")
                }
                Button { navigate(.new) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 27, height: 25)
                        .foregroundStyle(colors.accent)
                        .background(colors.soft, in: RoundedRectangle(cornerRadius: 7))
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
        return VStack(alignment: .leading, spacing: 15) {
            Text(entry.original == nil ? "新建提示词" : "编辑提示词")
                .font(.system(size: 22, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

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
                if entry.isDirty {
                    Text("有未保存的修改").foregroundStyle(colors.secondary)
                } else if let saveMessage {
                    Label(saveMessage, systemImage: "checkmark").foregroundStyle(colors.accent)
                }
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!entry.canSave || !entry.isDirty)
            }
            .font(.system(size: 12))
            .frame(minHeight: 32)
        }
        .padding(.horizontal, 27)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    @ObservedObject var store: PromptStore
    let colors: LibraryColors
    @ObservedObject var shortcutRecorder: ShortcutRecorder
    let onSaveShortcut: (HotKey) -> String?

    @ViewState private var shortcutError: String?
    @ViewState private var hasPermission = PasteService.hasPermission

    private var recording: Bool { shortcutRecorder.isRecording }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)

                section("全局快捷键", icon: "command") {
                    Text("在任意应用中呼出提示词面板。再次按下可收起。")
                        .foregroundStyle(colors.secondary)
                    HStack(spacing: 9) {
                        Text(recording ? "等待按键…" : store.shortcut.display)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(colors.accent)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(colors.soft, in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel(recording ? "等待输入快捷键" : "当前快捷键 \(store.shortcut.display)")
                        Spacer()
                        Button("恢复默认") { applyShortcut(.defaultValue) }
                            .disabled(recording || store.shortcut == .defaultValue)
                        Button(recording ? "取消录制" : "录制快捷键") { toggleRecording() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let shortcutError {
                        Label(shortcutError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(colors.warning)
                    } else if recording {
                        Text("按下组合键，例如 ⌃⌥P。按 Esc 取消。")
                            .foregroundStyle(colors.secondary)
                    }
                }

                section("辅助功能权限", icon: "accessibility") {
                    Text("授权后，Prompt Dock 可以把提示词填入其他应用已经聚焦的输入框。")
                        .foregroundStyle(colors.secondary)
                    HStack {
                        Label(hasPermission ? "已授权" : "待授权", systemImage: hasPermission ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(hasPermission ? colors.accent : colors.secondary)
                        Spacer()
                        if !hasPermission {
                            Button("打开系统设置", action: PasteService.requestPermission)
                        }
                    }
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

    private func toggleRecording() {
        shortcutError = nil
        if recording {
            shortcutRecorder.stop()
        } else {
            shortcutRecorder.start(
                onKeyDown: capture,
                onCurrentShortcut: { applyShortcut(store.shortcut) }
            )
        }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == kVK_Escape {
            shortcutRecorder.stop()
            shortcutError = nil
        } else if let shortcut = HotKey.capture(event) {
            applyShortcut(shortcut)
        } else {
            shortcutError = "请试试 ⌃⌥P 或 ⌘⇧P。复制、粘贴等常用快捷键已保留。"
        }
    }

    private func applyShortcut(_ shortcut: HotKey) {
        shortcutError = onSaveShortcut(shortcut)
        if shortcutError == nil { shortcutRecorder.stop() }
    }
}

private struct LibraryField: ViewModifier {
    let colors: LibraryColors

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

struct LibraryColors {
    let dark: Bool

    private func color(_ light: UInt32, _ darkValue: UInt32) -> Color {
        let value = dark ? darkValue : light
        return Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }

    var background: Color { color(0xF7F5EF, 0x222623) }
    var sidebar: Color { color(0xF1EFE8, 0x1C211E) }
    var surface: Color { color(0xFFFEFA, 0x2B302C) }
    var ink: Color { color(0x232D27, 0xF0F3ED) }
    var secondary: Color { color(0x59675E, 0xA8B4AC) }
    var accent: Color { color(0x166651, 0x89D9BA) }
    var soft: Color { color(0xE0EEE5, 0x30453B) }
    var icon: Color { color(0xDAE9DF, 0x34493E) }
    var line: Color { color(0xDADFD6, 0x404943) }
    var control: Color { color(0xEAEDE5, 0x1B221D) }
    var warning: Color { color(0x9E4B22, 0xFFBC89) }
}

@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private weak var window: NSWindow?
    private var keyMonitor: Any?
    private var onCurrentShortcut: (() -> Void)?

    func attach(to window: NSWindow) {
        stop()
        self.window = window
    }

    func start(onKeyDown: @escaping (NSEvent) -> Void, onCurrentShortcut: @escaping () -> Void) {
        guard let window else { return }
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

    func useCurrentShortcut() -> Bool {
        guard isRecording, let window, NSApp.keyWindow === window, NSApp.isActive else { return false }
        onCurrentShortcut?()
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

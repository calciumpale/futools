import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    private let model: PaletteModel
    private let voicePress = PaletteVoicePress()
    private var window: PaletteWindow?
    private var target: NSRunningApplication?

    var onInsert: ((String, NSRunningApplication?) -> Void)?
    var onNavigate: ((LibraryDestination) -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    init(store: PromptStore, optimizer: PromptOptimizer,
         recognizeScreenshot: @escaping @Sendable (OCRImage) async throws -> String = { try await ScreenshotOCR.recognize($0) }) {
        model = PaletteModel(store: store, optimizer: optimizer, recognizeScreenshot: recognizeScreenshot)
        super.init()
        model.performInsert = { [weak self] text in self?.insert(text) }
        model.navigate = { [weak self] destination in self?.onNavigate?(destination) }
        model.focusSearch = { [weak self] in self?.window?.focusSearch() }
        model.handleSearchCommand = { [weak self] command in
            self?.handleSearchCommand(command) ?? false
        }
        model.beginVoiceInput = { [weak self] in self?.beginVoiceInput() }
        model.prepareSearchForOCR = { [weak self] in
            self?.window?.pendingEnter = nil
            self?.window?.searchField?.unmarkText()
        }
        voicePress.canBegin = { [weak self] _ in
            guard let self else { return false }
            return self.isVisible && self.window?.isKeyWindow == true &&
                self.model.canStartVoice
        }
        voicePress.onBegin = { [weak self] in self?.beginVoiceInput() }
        voicePress.onEnd = { [weak self] in self?.model.voice.finish() }
        voicePress.onCancel = { [weak self] in
            guard let voice = self?.model.voice, voice.phase != .requestingPermission else { return }
            voice.cancel()
        }
    }

    func show(target: NSRunningApplication?, initialText: String? = nil) {
        guard let screen = screenUnderCursor() else { return }
        self.target = target
        model.prepare(for: target)
        if let initialText { model.setDraft(initialText) }
        let window = self.window ?? makeWindow()
        self.window = window

        let area = screen.visibleFrame
        let size = NSSize(width: min(PaletteView.width, max(1, area.width - 24)),
                          height: min(PaletteView.height, max(1, area.height - 20)))
        let top = min(max((area.height - size.height) * 0.26, 12), 150)
        let frame = NSRect(x: area.midX - size.width / 2, y: max(area.minY, area.maxY - size.height - top),
                           width: size.width, height: size.height)
        window.setFrame(frame, display: false)
        DockWindowMotion.present(window) { window.makeKeyAndOrderFront(nil) }
        window.focusSearch()
        window.invalidateShadow()
        model.canPressAnywhere = voicePress.start()
    }

    func dismiss(keepVoiceAuthorization: Bool = false) {
        voicePress.stop()
        window?.pendingEnter = nil
        model.removeScreenshot()
        if !keepVoiceAuthorization || model.voice.phase != .requestingPermission {
            model.voice.cancel()
        }
        if let window { DockWindowMotion.hide(window) }
        model.optimizer.cancel()
        target = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Allow the original key-window transition to finish before ordering the panel out.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.window?.isKeyWindow == false else { return }
            self.dismiss(keepVoiceAuthorization: true)
        }
    }

    private func beginVoiceInput() {
        guard isVisible, model.canStartVoice else { return }
        window?.pendingEnter = nil
        model.voice.begin { [weak self] text in self?.insertIntoDraft(text) }
    }

    func insertIntoDraft(_ text: String) {
        guard isVisible, let window else { return }
        window.focusSearch()
        guard let editor = window.searchField else {
            model.setDraft(model.optimizer.draft + text)
            return
        }
        if editor.hasMarkedText() {
            editor.unmarkText()
            model.setDraft(editor.string)
        }
        guard editor.string == model.optimizer.draft else {
            model.setDraft(model.optimizer.draft + text)
            return
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
        model.setDraft(editor.string)
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
        window.title = "futools 命令面板"
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
        let host = NSHostingView(rootView: PaletteView(
            model: model, store: model.store, optimizer: model.optimizer, voice: model.voice
        ))
        host.sizingOptions = []
        window.contentView = host
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
            guard model.voice.phase == .idle else { return true }
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
    let voice = VoiceInputController()
    private let recognizeScreenshot: @Sendable (OCRImage) async throws -> String
    private var recognitionTask: Task<Void, Never>?
    @Published private(set) var screenshot: OCRImage?
    @Published private(set) var showsOCR = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var screenshotError: String?
    @Published private(set) var screenshotAttachmentError: String?
    @Published var ocrResult = ""
    private(set) var screenshotPreview: NSImage?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var insertionTargetIcon: NSImage?
    @Published var canPressAnywhere = false

    var performInsert: ((String) -> Void)?
    var navigate: ((LibraryDestination) -> Void)?
    var focusSearch: (() -> Void)?
    var handleSearchCommand: ((Selector) -> Bool)?
    var beginVoiceInput: (() -> Void)?
    var prepareSearchForOCR: (() -> Void)?

    init(store: PromptStore, optimizer: PromptOptimizer,
         recognizeScreenshot: @escaping @Sendable (OCRImage) async throws -> String) {
        self.store = store
        self.optimizer = optimizer
        self.recognizeScreenshot = recognizeScreenshot
    }

    var matches: [Prompt] { store.matching(optimizer.draft) }
    var selectedPrompt: Prompt? { matches.first { $0.id == selectedID } }
    var navigatesMatches: Bool {
        !showsOCR && !optimizer.draft.contains(where: \.isNewline) && !matches.isEmpty
    }
    var canOptimize: Bool {
        !showsOCR && voice.phase == .idle && !optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canStartVoice: Bool { voice.phase == .idle && !optimizer.isOptimizing && !isRecognizing }
    var canRecognize: Bool { screenshot != nil && canStartVoice && (!showsOCR || screenshotError != nil) }
    var insertionText: String? {
        guard !optimizer.isOptimizing, !isRecognizing, voice.phase == .idle else { return nil }
        if showsOCR {
            guard screenshotError == nil, !ocrResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ocrResult
        }
        if let selectedPrompt { return selectedPrompt.body }
        let text = optimizer.hasResult ? optimizer.result : optimizer.draft
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    func prepare(for target: NSRunningApplication?) {
        insertionTargetIcon = PasteService.hasPermission ? target.map {
            $0.icon ?? NSWorkspace.shared.icon(for: .application)
        } : nil
        optimizer.reset()
        removeScreenshot()
        if voice.phase != .requestingPermission { voice.cancel() }
        selectedID = matches.first?.id
    }

    func setDraft(_ value: String) {
        guard optimizer.draft != value else { return }
        if showsOCR { removeScreenshot() }
        optimizer.draft = value
        optimizer.clearResult()
        selectedID = matches.first?.id
    }

    func pasteScreenshot(_ board: NSPasteboard) -> Bool {
        guard OCRImage.canRead(from: board) else { return false }
        do {
            let image = try OCRImage.read(from: board)
            removeScreenshot()
            screenshotPreview = image.preview
            screenshot = image
        } catch {
            screenshotAttachmentError = error.localizedDescription
        }
        return true
    }

    func removeScreenshot() {
        recognitionTask?.cancel()
        recognitionTask = nil
        if showsOCR { selectedID = matches.first?.id }
        showsOCR = false
        screenshot = nil
        screenshotPreview = nil
        screenshotError = nil
        screenshotAttachmentError = nil
        ocrResult = ""
        isRecognizing = false
    }

    func runOCR() {
        guard canRecognize, let screenshot else { return }
        prepareSearchForOCR?()
        optimizer.reset()
        selectedID = nil
        screenshotAttachmentError = nil
        screenshotError = nil
        ocrResult = ""
        isRecognizing = true
        showsOCR = true
        recognitionTask = Task { [weak self, recognizeScreenshot] in
            do {
                let text = try await recognizeScreenshot(screenshot)
                guard !Task.isCancelled, let self else { return }
                self.recognitionTask = nil
                self.ocrResult = text
                self.isRecognizing = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.recognitionTask = nil
                self.isRecognizing = false
                self.screenshotError = error.localizedDescription
            }
        }
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
    @ObservedObject var voice: VoiceInputController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var colors: DockColors { DockColors(dark: scheme == .dark) }

    var body: some View {
        GeometryReader { geometry in
            panel(resultWidth: min(308, floor(geometry.size.width * 0.455)))
        }
    }

    private func panel(resultWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            searchBar
            statusArea
            separator
            HStack(spacing: 0) {
                Group {
                    if model.showsOCR {
                        PaletteOCRImagePane(image: model.screenshotPreview, colors: colors)
                            .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                    } else {
                        results
                            .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                    }
                }
                .frame(width: resultWidth)
                Rectangle().fill(colors.line).frame(width: 1)
                if model.showsOCR {
                    PaletteOCRResultPane(
                        text: $model.ocrResult, isRecognizing: model.isRecognizing,
                        error: model.screenshotError, colors: colors, onRetry: model.runOCR
                    )
                    .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                } else {
                    preview
                        .transition(DockMotion.pageReveal(reduceMotion: reduceMotion))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(DockMotion.page(reduceMotion: reduceMotion), value: model.showsOCR)
            optimizationError
            separator
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var statusArea: some View {
        VStack(spacing: 0) {
            screenshotStatus
            voiceStatus
        }
        .animation(DockMotion.transition(reduceMotion: reduceMotion), value: model.screenshot != nil)
        .animation(DockMotion.transition(reduceMotion: reduceMotion), value: model.screenshotAttachmentError)
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: voiceStatusText)
    }

    private var optimizationError: some View {
        VStack(spacing: 0) {
            if let error = optimizer.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.warning)
                    .lineLimit(2)
                    .help(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 7)
                    .contentTransition(.opacity)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(DockMotion.transition(reduceMotion: reduceMotion), value: optimizer.errorMessage)
    }

    private var voiceStatusText: String? {
        switch voice.phase {
        case .idle: return voice.message
        case .requestingPermission: return "等待麦克风和语音识别授权…"
        case .recording: return voice.message ?? "正在录音，松开后转写"
        case .finishing: return "正在转写语音…"
        }
    }

    @ViewBuilder
    private var voiceStatus: some View {
        if let text = voiceStatusText {
            Text(text)
                .font(.system(size: 12))
                .contentTransition(.opacity)
                .foregroundStyle(voice.phase == .recording ? colors.accent : colors.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 19)
                .padding(.bottom, 7)
                .transition(DockMotion.reveal(reduceMotion: reduceMotion))
        }
    }

    private var searchBar: some View {
        HStack(alignment: .top, spacing: 13) {
            VoicePressButton(
                phase: voice.phase,
                isEnabled: !optimizer.isOptimizing && !model.isRecognizing,
                canPressAnywhere: model.canPressAnywhere,
                onBegin: { model.beginVoiceInput?() },
                onEnd: voice.finish,
                onCancel: {
                    if voice.phase != .requestingPermission { voice.cancel() }
                }
            )
            .frame(width: 32, height: PaletteTextEditor.searchMinimumHeight)
            PaletteTextEditor(
                text: Binding(get: { optimizer.draft }, set: model.setDraft),
                label: "搜索或输入提示词",
                fontSize: 18,
                textColor: colors.ink,
                accentColor: colors.accent,
                placeholder: "搜索或输入",
                isSearchEditor: true,
                onCommand: { model.handleSearchCommand?($0) ?? false },
                onOptimize: model.optimize,
                onPasteImage: model.pasteScreenshot
            )
            .frame(maxWidth: .infinity)
            clearButton
            ocrButton.frame(height: PaletteTextEditor.searchMinimumHeight)
            Button { model.navigate?(.library) } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.secondary)
                    .frame(width: 31, height: 29)
                    .background(colors.control, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(DockPressStyle())
            .frame(height: PaletteTextEditor.searchMinimumHeight)
            .help("管理提示词")
            .accessibilityLabel("管理提示词")
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 10)
    }

    private var clearButton: some View {
        let available = !optimizer.draft.isEmpty
        return Button {
            model.setDraft("")
            model.focusSearch?()
        } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                .foregroundStyle(colors.secondary)
                .frame(width: 24, height: 28)
        }
        .buttonStyle(DockPressStyle())
        .frame(height: PaletteTextEditor.searchMinimumHeight)
        .opacity(available ? 1 : 0)
        .disabled(!available)
        .accessibilityHidden(!available)
        .accessibilityLabel("清空输入")
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: available)
    }

    private var ocrButton: some View {
        Button(action: model.runOCR) {
            HStack(spacing: 4) {
                if model.isRecognizing {
                    DockActivityGlyph(isBusy: true)
                }
                Text("OCR").font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 56, height: 29)
            .foregroundStyle(model.canRecognize ? colors.accent : colors.secondary)
            .background(model.canRecognize ? colors.selection : colors.control, in: RoundedRectangle(cornerRadius: 7))
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: model.canRecognize)
        }
        .buttonStyle(DockPressStyle())
        .disabled(!model.canRecognize)
        .accessibilityLabel("OCR")
        .accessibilityValue(model.isRecognizing ? "正在识别" : "")
        .help(model.screenshot == nil ? "将截图粘贴到输入框" : "发送截图到 DeepSeek 识别")
    }

    @ViewBuilder
    private var screenshotStatus: some View {
        if model.screenshot != nil {
            HStack(spacing: 7) {
                if !model.showsOCR {
                    if let preview = model.screenshotPreview {
                        Image(nsImage: preview)
                            .resizable().scaledToFit()
                            .frame(width: 25, height: 21)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "photo").accessibilityHidden(true)
                    }
                    Text("截图已粘贴").font(.system(size: 11, weight: .medium))
                }
                Button(action: model.removeScreenshot) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                        if model.showsOCR { Text("移除截图") }
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除截图")
                .help("移除截图")
                Spacer()
            }
            .frame(minHeight: 21)
            .foregroundStyle(colors.secondary)
            .padding(.horizontal, 19)
            .padding(.bottom, 7)
            .transition(DockMotion.reveal(reduceMotion: reduceMotion))
        }
        if let error = model.screenshotAttachmentError {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(colors.warning)
                .lineLimit(2)
                .help(error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 19)
                .padding(.bottom, 7)
                .transition(DockMotion.reveal(reduceMotion: reduceMotion))
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(optimizer.draft.isEmpty ? "提示词" : "搜索结果")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(model.matches.count) 条")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 43, alignment: .trailing)
                    .contentTransition(.opacity)
                    .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: model.matches.count)
                    .accessibilityLabel("\(model.matches.count) 条提示词")
            }
            .foregroundStyle(colors.secondary)
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
                            .foregroundStyle(colors.secondary)
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
                    .foregroundStyle(selected ? colors.accent : colors.secondary)
                    .frame(width: 33, height: 33)
                    .background(selected ? colors.iconSelected : colors.control, in: RoundedRectangle(cornerRadius: 8))
                    .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: selected)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    if !prompt.category.isEmpty {
                        Text(prompt.category).font(.system(size: 11)).foregroundStyle(colors.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .opacity(selected ? 1 : 0)
                    .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: selected)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 51)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? colors.selection : Color.clear)
                    .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: selected)
            }
        }
        .buttonStyle(DockPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("编辑提示词") { model.navigate?(.prompt(prompt.id)) }
        }
    }

    private var preview: some View {
        let prompt = model.selectedPrompt
        return ZStack(alignment: .topLeading) {
            if let prompt {
                savedPromptPreview(prompt)
            } else if optimizer.hasResult {
                optimizedPreview
            }
            optimizationProgress(prompt == nil && !optimizer.hasResult && optimizer.isOptimizing)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.preview)
    }

    private func optimizationProgress(_ shown: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if shown {
                HStack(spacing: 7) {
                    DockActivityGlyph(isBusy: true)
                    Text("正在优化提示词…")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.secondary)
                .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: shown)
        .allowsHitTesting(false)
    }

    private func savedPromptPreview(_ prompt: Prompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text("提示词预览")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.secondary)
                Spacer()
                if optimizer.hasResult {
                    Button("选用结果") {
                        model.chooseResult()
                        model.focusSearch?()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.accent)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: prompt.title)
                            .font(.system(size: 19, weight: .semibold))
                            .contentTransition(.opacity)
                            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: prompt.id)
                            .accessibilityAddTraits(.isHeader)
                            .id(PreviewAnchor.title)
                        Text(verbatim: prompt.body)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(colors.body)
                            .contentTransition(.opacity)
                            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: prompt.id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: prompt.id) { _ in
                    proxy.scrollTo(PreviewAnchor.title, anchor: .top)
                }
            }
        }
    }

    private enum PreviewAnchor: Hashable { case title }

    private var optimizedPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text("优化结果")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("存为提示词") { model.navigate?(.newWithBody(optimizer.result)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(colors.accent)
                    .disabled(!canSaveResult)
            }
            .font(.system(size: 11))
            .foregroundStyle(colors.secondary)
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
    }

    private var canSaveResult: Bool {
        !optimizer.isOptimizing && !optimizer.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var insertTitle: String {
        model.insertionTargetIcon == nil ? "复制" : "插入"
    }

    private var footer: some View {
        let buttonShape = RoundedRectangle(cornerRadius: 8)
        let canRunOptimization = model.canOptimize || optimizer.isOptimizing
        let canInsert = model.insertionText != nil
        return HStack(spacing: 8) {
            footerKeyHints
                .opacity(model.showsOCR ? 0 : 1)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: model.showsOCR)
                .accessibilityHidden(model.showsOCR)
            Spacer(minLength: 4)
            Button {
                if optimizer.isOptimizing {
                    optimizer.cancel()
                } else {
                    model.optimize()
                }
            } label: {
                HStack(spacing: 6) {
                    DockActivityGlyph(isBusy: optimizer.isOptimizing, idleSymbol: "sparkles")
                    Text(optimizer.isOptimizing ? "取消优化" : "优化提示词")
                        .contentTransition(.opacity)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(canRunOptimization ? colors.ink : colors.secondary)
                .frame(width: 106, height: 30)
                .background(colors.control, in: buttonShape)
                .overlay {
                    buttonShape.strokeBorder(canRunOptimization ? colors.outline : colors.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: optimizer.isOptimizing)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: canRunOptimization)
            }
            .buttonStyle(DockPressStyle())
            .disabled(!canRunOptimization)
            .accessibilityLabel(optimizer.isOptimizing ? "取消优化" : "优化提示词")
            .help("⌘↩ 优化")

            Button { model.confirmSelection() } label: {
                HStack(spacing: 6) {
                    if let icon = model.insertionTargetIcon {
                        Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                            .accessibilityHidden(true)
                    }
                    Text(insertTitle)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 84, height: 30)
                .background(colors.action, in: buttonShape)
                .opacity(canInsert ? 1 : 0.4)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: canInsert)
            }
            .buttonStyle(DockPressStyle())
            .disabled(!canInsert)
            .accessibilityLabel(insertTitle)
            .help(insertTitle)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .frame(height: 49)
    }

    private var footerKeyHints: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                KeyCap(label: "↑", colors: colors)
                KeyCap(label: "↓", colors: colors)
                Text("切换").foregroundStyle(colors.secondary)
                KeyCap(label: "⇧↩", colors: colors).padding(.leading, 5)
                Text("换行").foregroundStyle(colors.secondary)
            }
            .fixedSize()

            HStack(spacing: 4) {
                KeyCap(label: "↑↓", colors: colors)
                KeyCap(label: "⇧↩", colors: colors)
            }
            .help("方向键切换 · Shift + Return 换行")
            .accessibilityLabel("方向键切换，Shift + Return 换行")
        }
    }

}

private struct KeyCap: View {
    let label: String
    let colors: DockColors

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(colors.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(colors.control, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(colors.line, lineWidth: 1) }
    }
}

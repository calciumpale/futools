import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MenuBarOCRDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    fileprivate enum Destination { case icon, panel }
    var isVisible: Bool { panel?.isVisible == true }

    private static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    private static var dropTypes: [NSPasteboard.PasteboardType] { OCRImage.draggedPasteboardTypes + promiseTypes }

    private weak var button: NSStatusBarButton?
    private let onOpenText: (String) -> Void
    private let recognitionService: @Sendable (OCRImage) async throws -> String
    private let state = OCRDropState()
    private var panel: OCRDropPanel?
    private var image: OCRImage?
    private var recognition: Task<Void, Never>?
    private var promiseDirectory: URL?
    private var promiseTimeout: Task<Void, Never>?
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var leaveTimer: Timer?
    private var hover: (sequence: Int, destination: Destination)?

    init(
        button: NSStatusBarButton,
        recognize: @escaping @Sendable (OCRImage) async throws -> String = { try await ScreenshotOCR.recognize($0) },
        onOpenText: @escaping (String) -> Void
    ) {
        self.button = button
        recognitionService = recognize
        self.onOpenText = onOpenText
        super.init()

        // Leave the status item's menu, cell, and action in AppKit's original responder chain.
        let target = OCRStatusDropTarget(frame: button.bounds)
        target.owner = self
        target.autoresizingMask = [.width, .height]
        target.setAccessibilityElement(false)
        target.registerForDraggedTypes(Self.dropTypes)
        button.addSubview(target, positioned: .above, relativeTo: nil)
    }

    func dismiss() {
        stopHover()
        if let promiseDirectory { clearPromise(in: promiseDirectory) }
        recognition?.cancel()
        recognition = nil
        image = nil
        state.phase = .waiting
        panel?.orderOut(nil)
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { entered(sender, at: .panel) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updated(sender, at: .panel) }
    func draggingExited(_ sender: (any NSDraggingInfo)?) { exited(sender, at: .panel) }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { canAccept(sender) }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { accept(sender) }

    fileprivate func entered(_ sender: any NSDraggingInfo, at destination: Destination) -> NSDragOperation {
        guard canAccept(sender) else { return [] }

        leaveTimer?.invalidate()
        leaveTimer = nil
        hover = (sender.draggingSequenceNumber, destination)
        state.isHovering = true
        showPanel()
        return copyOperation(for: sender)
    }

    fileprivate func updated(_ sender: any NSDraggingInfo, at destination: Destination) -> NSDragOperation {
        guard let hover, hover.sequence == sender.draggingSequenceNumber, hover.destination == destination else {
            return entered(sender, at: destination)
        }
        return copyOperation(for: sender)
    }

    fileprivate func exited(_ sender: (any NSDraggingInfo)?, at destination: Destination) {
        guard let hover, hover.destination == destination,
              sender == nil || sender?.draggingSequenceNumber == hover.sequence else { return }
        leaveTimer?.invalidate()
        // Crossing the screen gap dispatches icon exit before panel enter.
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishHover() }
        }
        leaveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    fileprivate func accept(_ sender: any NSDraggingInfo) -> Bool {
        guard canAccept(sender) else { return false }
        stopHover()
        do {
            if let promise = imagePromise(from: sender.draggingPasteboard) {
                try receive(promise)
            } else {
                recognize(try OCRImage.read(from: sender.draggingPasteboard))
            }
            return true
        } catch {
            showInputFailure(error.localizedDescription)
            return false
        }
    }

    fileprivate func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        guard recognition == nil, promiseDirectory == nil, !copyOperation(for: sender).isEmpty else { return false }
        let pasteboard = sender.draggingPasteboard
        return OCRImage.canRead(from: pasteboard) || imagePromise(from: pasteboard) != nil
    }

    private func imagePromise(from pasteboard: NSPasteboard) -> NSFilePromiseReceiver? {
        guard pasteboard.availableType(from: Self.promiseTypes) != nil,
              let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver], receivers.count == 1,
              let receiver = receivers.first, receiver.fileTypes.count == 1,
              let identifier = receiver.fileTypes.first,
              let type = UTType(identifier) ?? UTType(filenameExtension: identifier), type.conforms(to: .image) else {
            return nil
        }
        return receiver
    }

    private func receive(_ promise: NSFilePromiseReceiver) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-dock-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        promiseDirectory = directory
        image = nil
        state.phase = .preparing
        showPanel(makeKey: true)

        promiseTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.promiseDirectory == directory else { return }
            self.clearPromise(in: directory)
            self.showInputFailure("读取截图超时，请重新拖入。")
        }
        promise.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
            // Snapshot the bytes while AppKit holds its coordinated read on the delivered file.
            let result = Result { try Self.readPromise(url, in: directory, failed: error != nil) }
            Task { @MainActor [weak self] in
                guard let self, self.promiseDirectory == directory else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.clearPromise(in: directory)
                switch result {
                case .success(let image): self.recognize(image)
                case .failure(let error): self.showInputFailure(error.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func readPromise(_ url: URL, in directory: URL, failed: Bool) throws -> OCRImage {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let expected = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard !failed, url.isFileURL, resolved.deletingLastPathComponent().path == expected.path else {
            throw PromiseError.unavailable
        }
        return try OCRImage.read(fileURL: resolved)
    }

    private enum PromiseError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法接收这张截图，请重新拖入。" }
    }

    private func clearPromise(in directory: URL) {
        promiseTimeout?.cancel()
        promiseTimeout = nil
        promiseDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func showInputFailure(_ message: String) {
        image = nil
        state.phase = .failed(message, canRetry: false)
        showPanel(makeKey: true)
    }

    private func copyOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSourceOperationMask.contains(.copy) { return .copy }
        if sender.draggingSourceOperationMask.contains(.generic) { return .generic }
        return []
    }

    private func stopHover() {
        leaveTimer?.invalidate()
        leaveTimer = nil
        hover = nil
        state.isHovering = false
    }

    private func finishHover() {
        stopHover()
        if case .waiting = state.phase {
            panel?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func recognize(_ image: OCRImage) {
        guard recognition == nil else { return }
        self.image = image
        state.phase = .recognizing
        showPanel(makeKey: true)
        recognition = Task { [weak self, recognitionService] in
            do {
                let text = try await recognitionService(image)
                try Task.checkCancellation()
                self?.complete(with: .result(text))
            } catch {
                guard !Task.isCancelled else { return }
                self?.complete(with: .failed(error.localizedDescription, canRetry: true))
            }
        }
    }

    private func complete(with phase: OCRDropState.Phase) {
        recognition = nil
        if case .result = phase { image = nil }
        state.phase = phase
        showPanel()
    }

    private func retry() {
        if let image { recognize(image) }
    }

    private func openText(_ text: String) {
        dismiss()
        onOpenText(text)
    }

    private func showPanel(makeKey: Bool = false) {
        guard let button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 0)
        let size = state.panelSize
        let left = min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width)
        let top = min(anchor.minY - 3, available.maxY)
        panel.setFrame(NSRect(x: left, y: top - size.height, width: size.width, height: size.height), display: true)
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> OCRDropPanel {
        let panel = OCRDropPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.title = "Prompt Dock 截图识字"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.delegate = self
        panel.registerForDraggedTypes(Self.dropTypes)
        let host = NSHostingView(rootView: OCRDropPopup(
            state: state,
            onDismiss: { [weak self] in self?.dismiss() },
            onRetry: { [weak self] in self?.retry() },
            onOpenText: { [weak self] in self?.openText($0) }
        ))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

@MainActor
private final class OCRStatusDropTarget: NSView {
    weak var owner: MenuBarOCRDrop?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { superview?.acceptsFirstMouse(for: event) ?? false }
    override var mouseDownCanMoveWindow: Bool { superview?.mouseDownCanMoveWindow ?? false }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.entered(sender, at: .icon) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.updated(sender, at: .icon) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { owner?.exited(sender, at: .icon) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { owner?.exited(sender, at: .icon) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { owner?.canAccept(sender) ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { owner?.accept(sender) ?? false }
}

@MainActor
private final class OCRDropPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == kVK_Escape {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
private final class OCRDropState: ObservableObject {
    enum Phase {
        case waiting
        case preparing
        case recognizing
        case result(String)
        case failed(String, canRetry: Bool)
    }

    @Published var isHovering = false
    @Published var phase: Phase = .waiting

    var panelSize: CGSize {
        if isHovering { return CGSize(width: 322, height: 138) }
        switch phase {
        case .waiting, .preparing, .recognizing: return CGSize(width: 322, height: 138)
        case .failed: return CGSize(width: 322, height: 179)
        case .result: return CGSize(width: 352, height: 261)
        }
    }
}

private typealias OCRPopupState<Value> = SwiftUI.State<Value>

@MainActor
private struct OCRDropPopup: View {
    @ObservedObject var state: OCRDropState
    let onDismiss: () -> Void
    let onRetry: () -> Void
    let onOpenText: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @OCRPopupState private var copyFeedback: String?

    private var colors: LibraryColors { LibraryColors(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("截图识字", systemImage: "text.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭截图识字")
                .help("关闭（Esc）")
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(colors.ink)
        .tint(colors.accent)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).strokeBorder(colors.line).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var content: some View {
        if state.isHovering {
            dropHint
        } else {
            switch state.phase {
            case .waiting:
                dropHint
            case .preparing:
                processing("正在读取截图…")
            case .recognizing:
                processing("DeepSeek 正在识别…")
            case .result(let text):
                result(text)
            case .failed(let message, let canRetry):
                failure(message, canRetry: canRetry)
            }
        }
    }

    private func processing(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title).font(.system(size: 13)).foregroundStyle(colors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropHint: some View {
        VStack(spacing: 5) {
            Text("拖入截图")
                .font(.system(size: 14, weight: .semibold))
            Text("松开后发送到 DeepSeek 识别")
                .font(.system(size: 12))
                .foregroundStyle(colors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.soft, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(colors.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
    }

    private func result(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: .infinity)
            .background(colors.background, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 9) {
                if let copyFeedback {
                    Text(copyFeedback).font(.system(size: 11)).foregroundStyle(colors.secondary)
                }
                Spacer()
                Button("复制文字") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    copyFeedback = board.setString(text, forType: .string) ? "已复制" : "复制失败"
                }
                Button("在面板中打开") { onOpenText(text) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .onAppear { copyFeedback = nil }
    }

    private func failure(_ message: String, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("拖入截图可重新识别")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondary)
                Spacer()
                if canRetry {
                    Button("重试", action: onRetry).controlSize(.small)
                }
            }
        }
    }
}

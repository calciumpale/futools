import AppKit
import SwiftUI

@main
enum PromptDockApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = PromptStore()
    private let pasteService = PasteService()
    private let shortcutRecorder = ShortcutRecorder()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.handleHotKey() }
    private lazy var compactHotKey = GlobalHotKey { [weak self] in self?.handleCompactHotKey() }
    private lazy var copilotHotKey = GlobalHotKey { [weak self] in self?.handleCopilotHotKey() }
    private let optimizer = PromptOptimizer { try await DeepSeekPromptAPI.rewrite($0) }
    private lazy var palette = PaletteController(store: store, optimizer: optimizer)
    private let compactPanel = CompactPromptPanel(optimizer: PromptOptimizer { try await DeepSeekPromptAPI.rewrite($0) })
    private let copilotPanel = CompactPromptPanel(
        optimizer: PromptOptimizer { try await DeepSeekPromptAPI.rewrite($0) }, copilotLibrary: CopilotLibraryStore()
    )
    private let toast = ClipboardToast()
    private var statusItem: NSStatusItem?
    private var menuBarOCR: MenuBarOCRDrop?
    private var openItem: NSMenuItem?
    private var compactItem: NSMenuItem?
    private var copilotItem: NSMenuItem?
    private var libraryWindow: NSWindow?
    private var shortcutActive = false
    private var compactShortcutActive = false
    private var copilotShortcutActive = false
    private var isPasting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.applyStoredPreference()
        makeMainMenu()
        makeStatusMenu()
        shortcutActive = hotKey.register(store.shortcut)
        compactShortcutActive = compactHotKey.register(store.compactShortcut)
        copilotShortcutActive = copilotHotKey.register(store.copilotShortcut)
        palette.onInsert = { [weak self] text, app in self?.insert(text, into: app) }
        palette.onNavigate = { [weak self] destination in self?.showLibrary(destination) }
        compactPanel.onInsert = { [weak self] text, app, targetIsFocused in
            guard let self else { return .failed }
            return await self.performInsert(text, into: app, targetIsFocused: targetIsFocused,
                                            destination: ConversationApp(bundleIdentifier: app.bundleIdentifier)?.supportsCompactReply == true ? .conversation : .standard)
        }
        compactPanel.onTargetLost = { [weak self] in self?.showTargetLost() }
        compactPanel.onConversationSelectionLost = { [weak self] in
            self?.toast.show("请重新打开精简模式并框选会话消息区", symbol: "viewfinder")
        }
        compactPanel.mayPresent = { [weak self] in
            guard let self else { return false }
            return !self.palette.isVisible && !self.copilotPanel.isEnabled && self.menuBarOCR?.isVisible != true
        }
        copilotPanel.onInsert = { [weak self] text, app, targetIsFocused in
            guard let self else { return .failed }
            return await self.performInsert(text, into: app, targetIsFocused: targetIsFocused, destination: .conversation)
        }
        copilotPanel.onInsertAttachment = { [weak self] file, app, targetIsFocused in
            guard let self, !self.isPasting else { return .failed }
            self.isPasting = true
            defer { self.isPasting = false }
            return await self.pasteService.pasteAttachment(file, into: app, targetIsFocused: targetIsFocused)
        }
        copilotPanel.onCopilotNotice = { [weak self] message in self?.toast.show(message, symbol: "sidebar.right") }
        copilotPanel.onConversationSelectionLost = { [weak self] in
            self?.toast.show("会话窗口大小已变化，请重新框选消息。", symbol: "viewfinder")
        }
        copilotPanel.mayPresent = { [weak self] in
            guard let self else { return false }
            return !self.palette.isVisible && !self.compactPanel.isVisible && self.menuBarOCR?.isVisible != true
        }

        let didOpenKey = "didOpenLibrary"
        if !UserDefaults.standard.bool(forKey: didOpenKey) || !shortcutActive {
            UserDefaults.standard.set(true, forKey: didOpenKey)
            showLibrary(.settings)
        }
        if !shortcutActive {
            toast.show("这个快捷键无法启用，请在设置中换一个。", symbol: "keyboard")
        } else if !compactShortcutActive {
            toast.show("精简模式快捷键无法启用，请在设置中换一个。", symbol: "keyboard")
        } else if !copilotShortcutActive {
            toast.show("侧边 Copilot 快捷键无法启用，请在设置中换一个。", symbol: "keyboard")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(.library)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        palette.dismiss()
        compactPanel.dismiss()
        copilotPanel.dismiss()
        menuBarOCR?.dismiss()
    }

    private func makeMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 futools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        menu.addItem(app)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)

        let window = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.submenu = windowMenu
        menu.addItem(window)
        NSApp.mainMenu = menu
    }

    private func makeStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "futools")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "futools · 拖入截图识别"
        item.button?.setAccessibilityLabel("futools")

        let menu = NSMenu()
        menu.delegate = self
        openItem = addMenuItem("打开命令面板", action: #selector(openFromMenu), to: menu)
        compactItem = addMenuItem("精简模式", action: #selector(openCompactFromMenu), to: menu)
        copilotItem = addMenuItem("侧边 Copilot", action: #selector(openCopilotFromMenu), to: menu)
        addMenuItem("管理提示词…", action: #selector(openLibrary), to: menu)
        addMenuItem("新建提示词…", action: #selector(newPrompt), to: menu)
        menu.addItem(.separator())
        addMenuItem("设置…", action: #selector(openSettings), to: menu)
        addMenuItem("退出 futools", action: #selector(quit), to: menu)
        item.menu = menu
        statusItem = item
        if let button = item.button {
            menuBarOCR = MenuBarOCRDrop(button: button) { [weak self] text in self?.openOCRResult(text) }
        }
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        openItem?.title = shortcutActive ? "打开命令面板   \(store.shortcut.display)" : "打开命令面板"
        compactItem?.title = compactShortcutActive ? "精简模式   \(store.compactShortcut.display)" : "精简模式"
        copilotItem?.title = copilotShortcutActive ? "侧边 Copilot   \(store.copilotShortcut.display)" : "侧边 Copilot"
    }

    @objc private func openFromMenu() {
        let target = currentTarget()
        // Let the status menu finish tracking before making the panel key.
        DispatchQueue.main.async { [weak self] in self?.togglePalette(target: target) }
    }

    @objc private func openCompactFromMenu() {
        let target = currentTarget()
        DispatchQueue.main.async { [weak self] in self?.showCompact(target: target) }
    }

    @objc private func openCopilotFromMenu() {
        let target = currentTarget()
        DispatchQueue.main.async { [weak self] in self?.showCopilot(target: target) }
    }

    @objc private func openLibrary() { showLibrary(.library) }
    @objc private func newPrompt() { showLibrary(.new) }
    @objc private func openSettings() { showLibrary(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func handleHotKey() {
        if shortcutRecorder.useCurrentShortcut(store.shortcut) { return }
        togglePalette(target: currentTarget())
    }

    private func handleCompactHotKey() {
        if shortcutRecorder.useCurrentShortcut(store.compactShortcut) { return }
        showCompact(target: currentTarget())
    }

    private func handleCopilotHotKey() {
        if shortcutRecorder.useCurrentShortcut(store.copilotShortcut) { return }
        showCopilot(target: currentTarget())
    }

    private func currentTarget() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    private func togglePalette(target: NSRunningApplication?) {
        if palette.isVisible {
            palette.dismiss()
        } else if !isPasting {
            compactPanel.suspendPresentation()
            copilotPanel.suspendPresentation()
            menuBarOCR?.dismiss()
            toast.dismiss()
            palette.show(target: target)
        }
    }

    private func showCompact(target: NSRunningApplication?) {
        if copilotPanel.isEnabled { copilotPanel.dismiss() }
        if compactPanel.isEnabled {
            let retarget = target.map { compactPanel.shouldRetarget($0) } ?? false
            compactPanel.dismiss()
            if !retarget { return }
        }
        guard !isPasting else { return }
        guard PasteService.hasPermission else {
            toast.show("开启辅助功能权限后可使用精简模式", symbol: "accessibility")
            return
        }
        palette.dismiss()
        menuBarOCR?.dismiss()
        toast.dismiss()
        if let target, compactPanel.show(target: target) { return }
        if let conversation = ConversationApp(bundleIdentifier: target?.bundleIdentifier),
           conversation.supportsCompactReply, !compactPanel.lacksSpaceAbove {
            toast.show("请在同一块屏幕内打开\(conversation.name)聊天窗口", symbol: "viewfinder")
            return
        }
        let message = target != nil && compactPanel.lacksSpaceAbove
            ? "输入框上方空间不足，请移动目标窗口后重试"
            : "请先在目标 App 的输入框中放置光标"
        toast.show(message, symbol: "cursorarrow.rays")
    }

    private func showCopilot(target: NSRunningApplication?) {
        if copilotPanel.isEnabled {
            let retarget = target.map { copilotPanel.shouldRetarget($0) } ?? false
            copilotPanel.dismiss()
            if !retarget { return }
        }
        guard !isPasting else { return }
        guard let target, ConversationApp(bundleIdentifier: target.bundleIdentifier) != nil else {
            toast.show("请先打开微信、企业微信、飞书或钉钉的聊天窗口。", symbol: "sidebar.right")
            return
        }
        guard PasteService.hasPermission else {
            toast.show("开启辅助功能权限后可使用侧边 Copilot。", symbol: "accessibility")
            return
        }
        palette.dismiss()
        compactPanel.dismiss()
        menuBarOCR?.dismiss()
        toast.dismiss()
        if copilotPanel.show(target: target) { return }
        let message = copilotPanel.lacksSpaceAbove ? "会话窗口右侧空间不足，请退出全屏或缩小窗口。" : "请打开聊天窗口后再启动侧边 Copilot。"
        toast.show(message, symbol: "sidebar.right")
    }

    private func openOCRResult(_ text: String) {
        guard !isPasting else { return }
        let target = currentTarget()
        menuBarOCR?.dismiss()
        compactPanel.suspendPresentation()
        copilotPanel.suspendPresentation()
        toast.dismiss()
        if palette.isVisible {
            palette.insertIntoDraft(text)
        } else {
            palette.show(target: target, initialText: text)
        }
    }

    private func insert(_ text: String, into target: NSRunningApplication?) {
        Task { _ = await performInsert(text, into: target) }
    }

    private func performInsert(_ text: String, into target: NSRunningApplication?,
                               targetIsFocused: (@MainActor () -> Bool)? = nil,
                               destination: PasteService.Destination = .standard) async -> PasteOutcome {
        guard !isPasting else { return .failed }
        isPasting = true
        defer { isPasting = false }
        let result = await pasteService.paste(text, into: target, targetIsFocused: targetIsFocused,
                                              destination: destination)
        guard !Task.isCancelled else { return result }
        switch result {
        case .pasted:
            break
        case .copiedNoPermission:
            toast.show("已复制 · 开启辅助功能权限后可自动填入", symbol: "doc.on.doc")
        case .copiedNoTarget, .copiedTargetChanged:
            toast.show("已复制 · 在目标输入框按 ⌘V 粘贴", symbol: "doc.on.doc")
        case .copiedTerminal:
            toast.show("已复制多行提示词 · 请在终端确认后手动粘贴", symbol: "terminal")
        case .targetLostFocus:
            if destination == .standard { showTargetLost() }
        case .failed:
            if destination == .standard { toast.show("填入失败，请重试", symbol: "exclamationmark.circle") }
        }
        return result
    }

    private func showTargetLost() {
        toast.show("请将光标移回原输入框，再试一次", symbol: "cursorarrow.rays")
    }

    private func showLibrary(_ destination: LibraryDestination) {
        palette.dismiss()
        compactPanel.suspendPresentation()
        copilotPanel.dismiss()
        menuBarOCR?.dismiss()
        toast.dismiss()
        if let window = libraryWindow {
            activate()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { LibraryView.navigate(to: destination) }
            return
        }

        var selectedID: UUID?
        var startNew = false
        var newBody = ""
        var showSettings = false
        switch destination {
        case .library: break
        case .prompt(let id): selectedID = id
        case .new: startNew = true
        case .newWithBody(let text):
            startNew = true
            newBody = text
        case .settings: showSettings = true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 575),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "futools"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 520)
        shortcutRecorder.attach(to: window)
        window.contentView = NSHostingView(rootView: LibraryView(
            store: store, selectedID: selectedID, startNew: startNew, newBody: newBody, showSettings: showSettings,
            shortcutRecorder: shortcutRecorder,
            onSaveShortcut: { [weak self] shortcut in self?.saveShortcut(shortcut, forCompactPanel: false) },
            onSaveCompactShortcut: { [weak self] shortcut in self?.saveShortcut(shortcut, forCompactPanel: true) },
            onSaveCopilotShortcut: { [weak self] shortcut in self?.saveCopilotShortcut(shortcut) }
        ))
        window.center()
        libraryWindow = window
        activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func activate() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func saveShortcut(_ shortcut: HotKey, forCompactPanel compact: Bool) -> String? {
        guard shortcut != store.copilotShortcut else { return "这个快捷键已用于侧边 Copilot，请换一个。" }
        let previous = compact ? store.compactShortcut : store.shortcut
        let other = compact ? store.shortcut : store.compactShortcut
        guard shortcut != other else {
            return compact ? "这个快捷键已用于命令面板，请换一个。" : "这个快捷键已用于精简模式，请换一个。"
        }
        let registration = compact ? compactHotKey : hotKey
        let previousActive = compact ? compactShortcutActive : shortcutActive
        guard registration.register(shortcut) else { return "这个快捷键无法启用，可能已被其他应用占用。" }
        let saved = shortcut == previous || (compact ? store.setCompactShortcut(shortcut) : store.setShortcut(shortcut))
        let active = saved || (previousActive && registration.register(previous))
        if compact { compactShortcutActive = active } else { shortcutActive = active }
        if !saved {
            if !active { registration.unregister() }
            return store.storageError ?? "无法保存快捷键。"
        }
        return nil
    }

    private func saveCopilotShortcut(_ shortcut: HotKey) -> String? {
        guard shortcut != store.shortcut, shortcut != store.compactShortcut else {
            return "这个快捷键已用于其他面板，请换一个。"
        }
        let previous = store.copilotShortcut
        guard copilotHotKey.register(shortcut) else { return "这个快捷键无法启用，可能已被其他应用占用。" }
        if shortcut == previous || store.setCopilotShortcut(shortcut) {
            copilotShortcutActive = true
            return nil
        }
        copilotShortcutActive = copilotShortcutActive && copilotHotKey.register(previous)
        if !copilotShortcutActive { copilotHotKey.unregister() }
        return store.storageError ?? "无法保存快捷键。"
    }
}

@MainActor
private final class ClipboardToast {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, symbol: String) {
        dismiss()
        guard let screen = screenUnderCursor() else { return }
        let usable = screen.visibleFrame
        let view = HStack(spacing: 10) {
            Image(systemName: symbol).imageScale(.medium)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: min(400, max(1, usable.width - 24)))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
        .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let frame = NSRect(x: usable.midX - size.width / 2, y: usable.minY + 52,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        DockWindowMotion.present(panel) { panel.orderFrontRegardless() }
        self.panel = panel
        hideTask = Task { @MainActor [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, let panel else { return }
            self.hideTask = nil
            DockWindowMotion.close(panel) { [weak self, weak panel] in
                guard let self, let panel, self.panel === panel else { return }
                self.panel = nil
            }
        }
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        if let panel { DockWindowMotion.hide(panel) }
        panel = nil
    }
}

@MainActor
func screenUnderCursor() -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
}

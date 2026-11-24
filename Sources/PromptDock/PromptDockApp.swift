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
    private let optimizer = PromptOptimizer { try await DeepSeekPromptAPI.rewrite($0) }
    private lazy var palette = PaletteController(store: store, optimizer: optimizer)
    private let toast = ClipboardToast()
    private var statusItem: NSStatusItem?
    private var openItem: NSMenuItem?
    private var libraryWindow: NSWindow?
    private var shortcutActive = false
    private var isPasting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMainMenu()
        makeStatusMenu()
        shortcutActive = hotKey.register(store.shortcut)
        palette.onInsert = { [weak self] text, app in self?.insert(text, into: app) }
        palette.onNavigate = { [weak self] destination in self?.showLibrary(destination) }

        let didOpenKey = "didOpenLibrary"
        if !UserDefaults.standard.bool(forKey: didOpenKey) || !shortcutActive {
            UserDefaults.standard.set(true, forKey: didOpenKey)
            showLibrary(.settings)
        }
        if !shortcutActive {
            toast.show("这个快捷键无法启用，请在设置中换一个。", symbol: "keyboard")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(.library)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        optimizer.cancel()
    }

    private func makeMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Prompt Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Prompt Dock")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Prompt Dock"
        item.button?.setAccessibilityLabel("Prompt Dock")

        let menu = NSMenu()
        menu.delegate = self
        openItem = addMenuItem("打开命令面板", action: #selector(openFromMenu), to: menu)
        addMenuItem("管理提示词…", action: #selector(openLibrary), to: menu)
        addMenuItem("新建提示词…", action: #selector(newPrompt), to: menu)
        menu.addItem(.separator())
        addMenuItem("设置…", action: #selector(openSettings), to: menu)
        addMenuItem("退出 Prompt Dock", action: #selector(quit), to: menu)
        item.menu = menu
        statusItem = item
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        openItem?.title = shortcutActive ? "打开命令面板   \(store.shortcut.display)" : "打开命令面板"
    }

    @objc private func openFromMenu() {
        let target = currentTarget()
        // Let the status menu finish tracking before making the panel key.
        DispatchQueue.main.async { [weak self] in self?.togglePalette(target: target) }
    }

    @objc private func openLibrary() { showLibrary(.library) }
    @objc private func newPrompt() { showLibrary(.new) }
    @objc private func openSettings() { showLibrary(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func handleHotKey() {
        if shortcutRecorder.useCurrentShortcut() { return }
        togglePalette(target: currentTarget())
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
            toast.dismiss()
            palette.show(target: target)
        }
    }

    private func insert(_ text: String, into target: NSRunningApplication?) {
        guard !isPasting else { return }
        isPasting = true
        Task { @MainActor in
            let result = await pasteService.paste(text, into: target)
            isPasting = false
            switch result {
            case .pasted:
                break
            case .copiedNoPermission:
                toast.show("已复制 · 开启辅助功能权限后可自动填入", symbol: "doc.on.doc")
            case .copiedNoTarget, .copiedTargetChanged:
                toast.show("已复制 · 在目标输入框按 ⌘V 粘贴", symbol: "doc.on.doc")
            case .copiedTerminal:
                toast.show("已复制多行提示词 · 请在终端确认后手动粘贴", symbol: "terminal")
            case .failed:
                toast.show("填入失败，请重试", symbol: "exclamationmark.circle")
            }
        }
    }

    private func showLibrary(_ destination: LibraryDestination) {
        palette.dismiss()
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
        window.title = "Prompt Dock"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 520)
        shortcutRecorder.attach(to: window)
        window.contentView = NSHostingView(rootView: LibraryView(
            store: store, selectedID: selectedID, startNew: startNew, newBody: newBody, showSettings: showSettings,
            shortcutRecorder: shortcutRecorder,
            onSaveShortcut: { [weak self] shortcut in self?.saveShortcut(shortcut) }
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

    private func saveShortcut(_ shortcut: HotKey) -> String? {
        let previous = store.shortcut
        let previousActive = shortcutActive
        guard hotKey.register(shortcut) else { return "这个快捷键无法启用，可能已被其他应用占用。" }
        shortcutActive = true
        guard shortcut != previous else { return nil }
        guard store.setShortcut(shortcut) else {
            shortcutActive = false
            if previousActive {
                shortcutActive = hotKey.register(previous)
            }
            if !shortcutActive { hotKey.unregister() }
            return store.storageError ?? "无法保存快捷键。"
        }
        return nil
    }
}

@MainActor
private final class ClipboardToast {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, symbol: String) {
        dismiss()
        guard let screen = screenUnderCursor() else { return }
        let view = HStack(spacing: 10) {
            Image(systemName: symbol).imageScale(.medium)
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
        .fixedSize()
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let usable = screen.visibleFrame
        let frame = NSRect(x: usable.midX - size.width / 2, y: usable.minY + 52,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
func screenUnderCursor() -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
}

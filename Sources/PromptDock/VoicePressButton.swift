import AppKit
import SwiftUI

@MainActor
struct VoicePressButton: View {
    let phase: VoiceInputController.Phase
    let isEnabled: Bool
    let canPressAnywhere: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var colors: LibraryColors { LibraryColors(dark: scheme == .dark) }
    private var isRecording: Bool { phase == .recording }
    private var recordingColor: Color { scheme == .dark ? Color(red: 1, green: 0.6, blue: 0.57) : Color(red: 0.67, green: 0.21, blue: 0.18) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(isRecording ? recordingColor.opacity(0.13) : colors.control)
                .frame(width: 32, height: 29)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            if phase == .requestingPermission || phase == .finishing {
                ProgressView()
                    .controlSize(.small)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isRecording ? recordingColor : colors.accent)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VoicePressSurface(
                phase: phase, isEnabled: isEnabled, canPressAnywhere: canPressAnywhere,
                onBegin: onBegin, onEnd: onEnd, onCancel: onCancel
            )
        }
        .frame(width: 32, height: PaletteTextEditor.searchMinimumHeight)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct VoicePressSurface: NSViewRepresentable {
    let phase: VoiceInputController.Phase
    let isEnabled: Bool
    let canPressAnywhere: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PressView {
        let view = PressView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: PressView, context: Context) {
        view.update(phase: phase, enabled: isEnabled, canPressAnywhere: canPressAnywhere,
                    onBegin: onBegin, onEnd: onEnd, onCancel: onCancel)
    }

    static func dismantleNSView(_ view: PressView, coordinator: ()) {
        view.cancelHold(deferred: true)
    }

    final class PressView: NSView {
        private enum Hold { case waiting, pointer, accessibility }

        private var hold: Hold?
        private var token = UUID()
        private var thresholdTask: Task<Void, Never>?
        private var releaseMonitor: Any?
        private var phase: VoiceInputController.Phase = .idle
        private var enabled = false
        private var onBegin: (() -> Void)?
        private var onEnd: (() -> Void)?
        private var onCancel: (() -> Void)?

        deinit {
            thresholdTask?.cancel()
            if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func update(phase: VoiceInputController.Phase, enabled: Bool, canPressAnywhere: Bool, onBegin: @escaping () -> Void,
                    onEnd: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.phase = phase
            self.enabled = enabled
            self.onBegin = onBegin
            self.onEnd = onEnd
            self.onCancel = onCancel

            let label: String
            switch phase {
            case .idle:
                label = "按住说话，松开后转写"
            case .requestingPermission:
                label = "正在请求语音权限"
            case .recording:
                label = hold == .accessibility ? "正在录音，再按一次结束" : "正在录音，松开结束"
            case .finishing:
                label = "正在转写"
            }
            let pressHelp = canPressAnywhere
                ? "面板打开时，可直接长按触控板，松开后转写。"
                : "可按住麦克风说话。要直接长按触控板，请在系统设置中允许辅助功能。"
            toolTip = phase == .idle ? pressHelp : label
            setAccessibilityLabel(label)
            setAccessibilityHelp("\(pressHelp)旁白按一次开始说话，再按一次结束。")
            setAccessibilityEnabled(enabled && phase != .finishing)

            if !enabled {
                cancelHold(deferred: true)
            } else if hold == .accessibility, phase == .idle {
                _ = clearHold()
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard enabled, phase == .idle, hold == nil, let window, window.isVisible else { return }
            let press = UUID()
            token = press
            hold = .waiting

            releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] release in
                self?.endPointerHold()
                return release
            }
            thresholdTask = Task { [weak self, weak window] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.token == press, self.hold == .waiting else { return }
                guard self.enabled, self.phase == .idle, let window, self.window === window, window.isKeyWindow,
                      window.isVisible else {
                    self.cancelHold()
                    return
                }
                self.thresholdTask = nil
                self.hold = .pointer
                self.onBegin?()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if hold == .waiting, !bounds.insetBy(dx: -6, dy: -6).contains(convert(event.locationInWindow, from: nil)) {
                cancelHold()
            }
        }

        override func mouseUp(with event: NSEvent) { endPointerHold() }

        override func accessibilityPerformPress() -> Bool {
            guard enabled, window?.isVisible == true else { return false }
            if hold == .accessibility {
                _ = clearHold()
                onEnd?()
                return true
            }
            guard phase == .idle, hold == nil else { return false }
            token = UUID()
            hold = .accessibility
            onBegin?()
            return true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow {
                if let window {
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
                    cancelHold(deferred: true)
                }
                if let newWindow {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                           name: NSWindow.didResignKeyNotification, object: newWindow)
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowResignedKey() { cancelHold() }

        func cancelHold(deferred: Bool = false) {
            guard let previous = clearHold(), previous != .waiting else { return }
            if deferred {
                let canceled = token
                let callback = onCancel
                // SwiftUI may be dismantling or updating the represented view.
                DispatchQueue.main.async { [weak self] in
                    guard (self?.token ?? canceled) == canceled else { return }
                    callback?()
                }
            } else {
                onCancel?()
            }
        }

        private func endPointerHold() {
            guard hold != .accessibility else { return }
            if clearHold() == .pointer { onEnd?() }
        }

        private func clearHold() -> Hold? {
            let previous = hold
            hold = nil
            thresholdTask?.cancel()
            thresholdTask = nil
            if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
            releaseMonitor = nil
            return previous
        }
    }
}

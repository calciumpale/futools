import AppKit
import SwiftUI

@MainActor
struct CompactPromptView: View {
    static let baseHeight: CGFloat = 48
    private static let feedbackHeight: CGFloat = 34

    @ObservedObject var optimizer: PromptOptimizer
    @ObservedObject var voice: VoiceInputController
    let canPressAnywhere: Bool
    let optimize: () -> Void
    let optimizeFromKeyboard: () -> Void
    let onBeginVoice: () -> Void
    let onEndVoice: () -> Void
    let onCancelVoice: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var colors: DockColors { DockColors(dark: scheme == .dark) }

    private var canOptimize: Bool {
        voice.phase == .idle && !optimizer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func panelHeight(optimizer: PromptOptimizer, voice: VoiceInputController) -> CGFloat {
        feedback(optimizer: optimizer, voice: voice) == nil ? baseHeight : baseHeight + feedbackHeight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                if geometry.size.height >= Self.baseHeight + Self.feedbackHeight - 0.5,
                   let feedback = Self.feedback(optimizer: optimizer, voice: voice) {
                    Text(feedback.text)
                        .font(.system(size: 12))
                        .contentTransition(.opacity)
                        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: feedback.text)
                        .foregroundStyle(feedback.isError ? colors.warning : colors.secondary)
                        .lineLimit(2)
                        .help(feedback.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: Self.feedbackHeight)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(colors.line).frame(height: 1)
                        }
                }

                inputRow(showsActionIcon: geometry.size.width >= 280)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .background(colors.surface, in: shape)
        .overlay {
            shape.strokeBorder(colors.outline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .tint(colors.action)
    }

    private func inputRow(showsActionIcon: Bool) -> some View {
        HStack(spacing: 10) {
            PaletteTextEditor(
                text: $optimizer.draft, label: "提示词草稿", fontSize: 14,
                textColor: colors.ink, accentColor: colors.accent, placeholder: "输入提示词",
                placeholderColor: colors.secondary, fixedViewportHeight: 32,
                isSearchEditor: true, onOptimize: optimizeFromKeyboard
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                VoicePressButton(
                    phase: voice.phase, isEnabled: !optimizer.isOptimizing, canPressAnywhere: canPressAnywhere,
                    onBegin: onBeginVoice, onEnd: onEndVoice, onCancel: onCancelVoice, style: .compact
                )
                optimizeButton(showsIcon: showsActionIcon)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: Self.baseHeight)
    }

    private func optimizeButton(showsIcon: Bool) -> some View {
        let isReady = canOptimize && !optimizer.isOptimizing
        return Button {
            if optimizer.isOptimizing { optimizer.cancel() } else { optimize() }
        } label: {
            HStack(spacing: 5) {
                if showsIcon || optimizer.isOptimizing {
                    DockActivityGlyph(isBusy: optimizer.isOptimizing, idleSymbol: "sparkles")
                }
                Text(optimizer.isOptimizing ? "取消优化" : "优化提示词")
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isReady ? Color.white : colors.secondary)
            .frame(width: showsIcon ? 94 : 72, height: 30)
            .background(isReady ? colors.action : colors.control, in: RoundedRectangle(cornerRadius: 8))
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: optimizer.isOptimizing)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isReady)
        }
        .buttonStyle(DockPressStyle())
        .disabled(!canOptimize && !optimizer.isOptimizing)
        .accessibilityLabel(optimizer.isOptimizing ? "取消优化" : "优化提示词")
        .help(optimizer.isOptimizing ? "取消本次优化" : "优化提示词（⌘↩）")
    }

    private static func feedback(optimizer: PromptOptimizer, voice: VoiceInputController) -> Feedback? {
        switch voice.phase {
        case .requestingPermission: return Feedback(text: "等待麦克风和语音识别授权…")
        case .recording: return Feedback(text: voice.message ?? "正在录音，松开后转写")
        case .finishing: return Feedback(text: "正在转写语音…")
        case .idle:
            if let error = optimizer.errorMessage { return Feedback(text: error, isError: true) }
            return voice.message.map { Feedback(text: $0) }
        }
    }

    private struct Feedback {
        let text: String
        var isError = false
    }
}

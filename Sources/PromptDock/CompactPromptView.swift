import AppKit
import SwiftUI

@MainActor
struct CompactPromptView: View {
    static let baseHeight: CGFloat = 64
    private static let feedbackHeight: CGFloat = 37

    @ObservedObject var optimizer: PromptOptimizer
    @ObservedObject var voice: VoiceInputController
    let canPressAnywhere: Bool
    let optimize: () -> Void
    let optimizeFromKeyboard: () -> Void
    let onBeginVoice: () -> Void
    let onEndVoice: () -> Void
    let onCancelVoice: () -> Void

    @Environment(\.colorScheme) private var scheme

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
                        .foregroundStyle(feedback.isError ? Color(nsColor: .systemRed) : Color.secondary)
                        .lineLimit(2)
                        .help(feedback.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .frame(height: Self.feedbackHeight)
                }

                inputRow
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
        .background {
            shape.fill(scheme == .dark ? Color.black.opacity(0.10) : Color.white.opacity(0.17))
                .background(.regularMaterial, in: shape)
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.18 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            VoicePressButton(
                phase: voice.phase, isEnabled: !optimizer.isOptimizing, canPressAnywhere: canPressAnywhere,
                onBegin: onBeginVoice, onEnd: onEndVoice, onCancel: onCancelVoice, style: .compact
            )

            PaletteTextEditor(
                text: $optimizer.draft, label: "提示词草稿", fontSize: 15,
                textColor: Color(nsColor: .labelColor), accentColor: .accentColor, placeholder: "输入提示词",
                isSearchEditor: true, onOptimize: optimizeFromKeyboard
            )
            .frame(maxWidth: .infinity)
            .frame(height: PaletteTextEditor.searchMinimumHeight)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 8))

            optimizeButton
        }
        .padding(.horizontal, 11)
        .frame(height: Self.baseHeight)
    }

    @ViewBuilder private var optimizeButton: some View {
        if optimizer.isOptimizing {
            Button(action: optimizer.cancel) {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("取消")
                }
                .frame(minWidth: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("取消优化")
        } else {
            Button(action: optimize) {
                Text("优化提示词")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canOptimize)
            .accessibilityLabel("优化提示词")
            .help("优化提示词（⌘↩）")
        }
    }

    private static func feedback(optimizer: PromptOptimizer, voice: VoiceInputController) -> Feedback? {
        switch voice.phase {
        case .requestingPermission: return Feedback(text: "等待语音授权…")
        case .recording: return Feedback(text: voice.message ?? "正在听，松开后转写")
        case .finishing: return Feedback(text: "正在转写…")
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

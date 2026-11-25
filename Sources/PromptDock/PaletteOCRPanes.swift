import AppKit
import SwiftUI

struct PaletteOCRImagePane: View {
    let image: NSImage?
    let colors: DockColors

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("截图预览")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.secondary)
                .accessibilityAddTraits(.isHeader)

            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .accessibilityLabel("已粘贴的截图")
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                } else {
                    Label("预览不可用", systemImage: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondary)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.background, in: RoundedRectangle(cornerRadius: 8))
            .animation(DockMotion.transition(reduceMotion: reduceMotion), value: image != nil)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PaletteOCRResultPane: View {
    @Binding var text: String
    let isRecognizing: Bool
    let error: String?
    let colors: DockColors
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable {
        case recognizing, failure(String), result
    }

    private var phase: Phase {
        if isRecognizing { return .recognizing }
        if let error { return .failure(error) }
        return .result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别结果")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.secondary)
                .accessibilityAddTraits(.isHeader)

            ZStack {
                if phase == .result {
                    PaletteTextEditor(
                        text: $text, label: "识别结果正文", fontSize: 14,
                        textColor: colors.body, accentColor: colors.accent
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                status(phase)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.preview)
    }

    private func status(_ phase: Phase) -> some View {
        ZStack {
            switch phase {
            case .recognizing:
                HStack(spacing: 7) {
                    DockActivityGlyph(isBusy: true)
                    Text("正在识别截图…")
                }
                .font(.system(size: 13))
                .foregroundStyle(colors.secondary)
                .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            case .failure(let error):
                errorContent(error)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
            case .result:
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(phase != .result)
        .animation(DockMotion.transition(reduceMotion: reduceMotion), value: phase)
    }

    private func errorContent(_ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.warning)
                    .contentTransition(.opacity)
                Button("重试", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

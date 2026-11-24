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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别结果")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.secondary)
                .accessibilityAddTraits(.isHeader)

            ZStack {
                if isRecognizing {
                    HStack(spacing: 7) {
                        DockActivityGlyph(isBusy: true)
                        Text("正在识别截图…")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(colors.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                } else if let error {
                    errorContent(error)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                } else {
                    PaletteTextEditor(
                        text: $text, label: "识别结果正文", fontSize: 14,
                        textColor: colors.body, accentColor: colors.accent
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .animation(DockMotion.transition(reduceMotion: reduceMotion), value: isRecognizing)
            .animation(DockMotion.transition(reduceMotion: reduceMotion), value: error != nil)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.preview)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("重试", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

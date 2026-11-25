import AppKit
import SwiftUI

private typealias StyleState<Value> = SwiftUI.State<Value>

struct CopilotTheme {
    let dark: Bool
    let base: DockColors

    init(dark: Bool) {
        self.dark = dark
        self.base = DockColors(dark: dark)
    }

    // Layered surfaces
    var canvas: Color { base.background }
    var headerSurface: Color { color(0xFBFBFE, 0x202024) }
    var card: Color { base.surface }
    var cardElevated: Color { color(0xFFFFFF, 0x29292E) }
    var cardSubtle: Color { color(0xF1F2F6, 0x1E1E22) }
    var composerSurface: Color { color(0xFFFFFF, 0x25252A) }
    var pillTrack: Color { color(0xEAEAEE, 0x2B2B31) }
    var pillActive: Color { color(0xFFFFFF, 0x383840) }
    var hoverFill: Color { color(0xECEEF3, 0x2F2F36) }

    // Borders & elevation
    var rimHighlight: Color { dark ? Color.white.opacity(0.08) : Color.white.opacity(0.82) }
    var cardBorder: Color { dark ? Color.white.opacity(0.085) : Color.black.opacity(0.075) }
    var cardBorderFocused: Color { base.accent.opacity(dark ? 0.65 : 0.55) }
    var cardShadow: Color { dark ? Color.black.opacity(0.24) : Color.black.opacity(0.045) }
    var pillShadow: Color { dark ? Color.black.opacity(0.28) : Color.black.opacity(0.08) }

    // Semantic accents
    var success: Color { color(0x16803C, 0x4ADE80) }
    var successSoft: Color { color(0xE6F6EC, 0x183324) }
    var warningSoft: Color { color(0xFDF1E6, 0x3A281A) }
    var accentSoft: Color { base.selection }
    var userBubble: Color { color(0xE6F0FD, 0x223856) }
    var userBubbleBorder: Color { color(0xC9DFFB, 0x304F78) }

    // Kind badges
    func kindTint(_ kind: CopilotMaterial.Kind) -> (foreground: Color, background: Color) {
        switch kind {
        case .text:
            return (color(0x2F5CD1, 0x8CB4FF), color(0xEBF1FE, 0x1F2D49))
        case .link:
            return (color(0x0E7C7B, 0x5EEAD4), color(0xE5F6F5, 0x163333))
        case .image:
            return (color(0xB45309, 0xFBBF24), color(0xFEF3E2, 0x382A16))
        case .video:
            return (color(0x7C3AED, 0xC4B5FD), color(0xF3ECFE, 0x2C2144))
        }
    }

    // Host conversation app indicator color
    func appTint(for appName: String) -> Color {
        switch appName {
        case ConversationApp.weChat.name:
            return color(0x07C160, 0x34D399)
        case ConversationApp.feishu.name:
            return color(0x3370FF, 0x60A5FA)
        case ConversationApp.weCom.name:
            return color(0x267EF0, 0x5BA4FF)
        case ConversationApp.dingTalk.name:
            return color(0x0089FF, 0x38BDF8)
        default:
            return base.accent
        }
    }

    private func color(_ light: UInt32, _ darkValue: UInt32) -> Color {
        let value = dark ? darkValue : light
        return Color(
            .sRGB,
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }
}

enum CopilotPasteboard {
    @MainActor
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

struct CopilotCardStyle: ViewModifier {
    let theme: CopilotTheme
    var cornerRadius: CGFloat = 10
    var focused: Bool = false
    var subtle: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(subtle ? theme.cardSubtle : theme.card, in: shape)
            .overlay {
                shape.strokeBorder(
                    focused ? theme.cardBorderFocused : theme.cardBorder,
                    lineWidth: focused ? 1.25 : 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: subtle ? .clear : theme.cardShadow, radius: 3, x: 0, y: 1)
    }
}

extension View {
    func copilotCard(
        _ theme: CopilotTheme,
        cornerRadius: CGFloat = 10,
        focused: Bool = false,
        subtle: Bool = false
    ) -> some View {
        modifier(CopilotCardStyle(theme: theme, cornerRadius: cornerRadius, focused: focused, subtle: subtle))
    }
}

struct CopilotHoverRow: ViewModifier {
    let theme: CopilotTheme
    var cornerRadius: CGFloat = 10
    var isSelected: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StyleState private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                isSelected ? theme.accentSoft : (hovered ? theme.cardElevated : theme.card),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    isSelected ? theme.cardBorderFocused : (hovered ? theme.base.outline : theme.cardBorder),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: theme.cardShadow, radius: hovered ? 4 : 2, x: 0, y: 1)
            .onHover { hovered = $0 }
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: hovered)
            .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isSelected)
    }
}

struct CopilotIconHoverButton: View {
    let symbol: String
    let theme: CopilotTheme
    var tint: Color? = nil
    var size: CGFloat = 26
    var iconSize: CGFloat = 11.5
    var helpText: String
    var accessibilityLabel: String? = nil
    var isActive: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StyleState private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isActive ? theme.base.accent : (tint ?? theme.base.secondary))
                .frame(width: size, height: size)
                .background(
                    isActive ? theme.accentSoft : (hovered ? theme.hoverFill : Color.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHover { hovered = $0 }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: hovered)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel ?? helpText)
    }
}

struct CopilotSectionTitle: View {
    let title: String
    var symbol: String? = nil
    let theme: CopilotTheme

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.base.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.base.secondary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct CopilotPillToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let theme: CopilotTheme
    var isDisabled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StyleState private var hovered = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? theme.base.accent : theme.base.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                isOn ? theme.accentSoft : (hovered ? theme.hoverFill : theme.base.control),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    isOn ? theme.base.accent.opacity(theme.dark ? 0.38 : 0.28) : theme.cardBorder,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(DockPressStyle())
        .disabled(isDisabled)
        .onHover { hovered = $0 }
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: isOn)
        .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: hovered)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct CopilotToastPill: View {
    let message: String
    let symbol: String
    let theme: CopilotTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.success)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.base.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.cardElevated, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(theme.base.outline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(theme.dark ? 0.35 : 0.12), radius: 8, x: 0, y: 3)
    }
}

/// Lightweight native Markdown block renderer for Agent responses (macOS 13+).
struct CopilotMarkdownText: View {
    let markdown: String
    let theme: CopilotTheme
    var fontSize: CGFloat = 12.5

    var body: some View {
        let blocks = Self.parseBlocks(markdown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inlineText(text)
                        .font(.system(size: level <= 2 ? fontSize + 1.5 : fontSize + 0.5, weight: .semibold))
                        .foregroundStyle(theme.base.ink)
                        .padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(theme.base.accent)
                        inlineText(text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(theme.base.body)
                            .lineSpacing(3)
                    }
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).")
                            .font(.system(size: fontSize - 0.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.base.accent)
                            .frame(minWidth: 16, alignment: .trailing)
                        inlineText(text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(theme.base.body)
                            .lineSpacing(3)
                    }
                case .quote(let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(theme.base.accent.opacity(0.5))
                            .frame(width: 2.5)
                        inlineText(text)
                            .font(.system(size: fontSize - 0.5))
                            .foregroundStyle(theme.base.secondary)
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 2)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: fontSize - 1, design: .monospaced))
                            .foregroundStyle(theme.base.ink)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.cardSubtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(theme.cardBorder)
                            .allowsHitTesting(false)
                    }
                case .paragraph(let text):
                    inlineText(text)
                        .font(.system(size: fontSize))
                        .foregroundStyle(theme.base.body)
                        .lineSpacing(3.5)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inlineText(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(verbatim: source)
    }

    private enum Block {
        case heading(Int, String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case paragraph(String)
    }

    private static func parseBlocks(_ raw: String) -> [Block] {
        let lines = raw.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var paragraphBuffer: [String] = []
        var inCodeFence = false
        var codeBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: "\n")))
            paragraphBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCodeFence {
                    blocks.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
                    inCodeFence = false
                } else {
                    inCodeFence = true
                }
                continue
            }
            if inCodeFence {
                codeBuffer.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.level, heading.text))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let numbered = parseNumbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(numbered.number, numbered.text))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraphBuffer.append(line)
            }
        }
        if inCodeFence, !codeBuffer.isEmpty {
            blocks.append(.code(codeBuffer.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...4).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes, title)
    }

    private static func parseNumbered(_ line: String) -> (number: String, text: String)? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let prefix = line[..<dot]
        guard prefix.count <= 3, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let text = line[line.index(after: afterDot)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (String(prefix), text)
    }
}

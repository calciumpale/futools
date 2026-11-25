import Foundation

struct WeChatReplySpeakers {
    enum ScreenshotSide: String {
        case left = "左侧"
        case right = "右侧"
    }

    static let unlocatedScreenshotLine = "未定位"

    struct Message: Identifiable, Equatable {
        enum Speaker { case selfUser, counterpart, unknown }

        let id: Int
        let text: String
        let speaker: Speaker
        let screenshotSide: ScreenshotSide?

        var positionHint: String? { screenshotSide.map { "截图\($0.rawValue)" } }
    }

    private let fromScreenshot: Bool
    private let inferSidesFromScreenshot: Bool
    private let originalLines: [String]
    private let messages: [Message]

    init(_ transcript: String, fromScreenshot: Bool, inferSidesFromScreenshot: Bool = true) {
        self.fromScreenshot = fromScreenshot
        self.inferSidesFromScreenshot = inferSidesFromScreenshot
        let lines = transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        originalLines = lines
        messages = lines.enumerated().compactMap {
            Self.message(at: $0.offset, line: $0.element.trimmingCharacters(in: .whitespaces), fromScreenshot: fromScreenshot)
        }
    }

    var confirmedCounterpart: Message? {
        guard let latest = messages.last, latest.speaker == .counterpart else { return nil }
        return latest
    }

    var selectableCounterparts: [Message] {
        Array(messages.reversed().filter { $0.speaker != .selfUser }.prefix(12))
    }

    func transcript(includingCounterpart message: Message) -> String {
        guard message.speaker != .selfUser, messages.contains(message) else { return "" }
        if fromScreenshot { return screenshotTranscript(respondingTo: message) }
        var lines = originalLines
        if message.speaker == .unknown { lines[message.id] = "对方：\(message.text)" }
        return lines.joined(separator: "\n")
    }

    private func screenshotTranscript(respondingTo confirmed: Message) -> String {
        var recent: [String] = []
        var remaining = 3_500
        for message in messages.reversed() {
            let prefix: String
            if message.id == confirmed.id {
                prefix = "对方："
            } else if inferSidesFromScreenshot, let selectedSide = confirmed.screenshotSide, let side = message.screenshotSide {
                prefix = side == selectedSide ? "对方侧：" : "我方："
            } else {
                prefix = "说话人未确认："
            }
            let available = remaining - prefix.count - (recent.isEmpty ? 0 : 1)
            guard available > 0 else { break }
            if message.text.count > available {
                if recent.isEmpty { recent.append(prefix + String(message.text.suffix(available))) }
                break
            }
            recent.append(prefix + message.text)
            remaining = available - message.text.count
        }
        return recent.reversed().joined(separator: "\n")
    }

    private static func message(at index: Int, line: String, fromScreenshot: Bool) -> Message? {
        guard !line.isEmpty, !isTimestamp(line) else { return nil }
        guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return Message(id: index, text: line, speaker: .unknown, screenshotSide: nil)
        }
        let prefix = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if fromScreenshot {
            let side = ScreenshotSide(rawValue: prefix)
            if side != nil || prefix == unlocatedScreenshotLine {
                guard !text.isEmpty, side != nil || !isTimestamp(text) else { return nil }
                return Message(id: index, text: text, speaker: .unknown, screenshotSide: side)
            }
        } else {
            let role: Message.Speaker?
            switch prefix {
            case "我", "我方", "本人", "自己", "me": role = .selfUser
            case "对方", "对方说", "他", "她", "other", "them": role = .counterpart
            default: role = nil
            }
            if let role {
                return text.isEmpty ? nil : Message(id: index, text: text, speaker: role, screenshotSide: nil)
            }
        }
        return Message(id: index, text: line, speaker: .unknown, screenshotSide: nil)
    }

    private static func isTimestamp(_ line: String) -> Bool {
        let timestamp = #"^(?:\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?\s*)?(?:上午|下午)?\s*\d{1,2}[:：]\d{2}(?:[:：]\d{2})?$"#
        return line.range(of: timestamp, options: .regularExpression) != nil
    }
}

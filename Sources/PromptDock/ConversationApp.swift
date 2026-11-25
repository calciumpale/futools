enum ConversationApp: String {
    case weChat = "com.tencent.xinwechat"
    case feishu = "com.bytedance.macos.feishu"
    case weCom = "com.tencent.weworkmac"
    case dingTalk = "com.alibaba.dingtalkmac"

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return nil }
        self.init(rawValue: bundleIdentifier.lowercased())
    }

    var name: String {
        switch self {
        case .weChat: return "微信"
        case .feishu: return "飞书"
        case .weCom: return "企业微信"
        case .dingTalk: return "钉钉"
        }
    }

    var replyConsentKey: String {
        switch self {
        case .weChat: return "weChatReplySharesRecognizedText"
        case .feishu: return "feishuReplySharesRecognizedText"
        case .weCom: return "weComReplySharesRecognizedText"
        case .dingTalk: return "dingTalkReplySharesRecognizedText"
        }
    }

    var supportsCompactReply: Bool { self == .weChat || self == .feishu }
}

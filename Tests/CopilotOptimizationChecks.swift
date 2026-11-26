import CoreGraphics
import Foundation

@main
@MainActor
enum CopilotOptimizationChecks {
    private static let fakeKey = "promptdock-copilot-test-placeholder"

    static func main() async {
        do {
            try dockLayoutSupportsLeftRightAndFallback()
            try await libraryDecodesLegacyJSONAndSupportsPinsTagsAndKindFilter()
            try await apiSupportsPolishReplyReferenceMaterialsAndMultiTurnAgent()
            try await apiDeliversCustomReplyTones()
            try await apiSuggestsRepliesFromDraftAlone()
            try agentModelTracksChatContextAndResetsCleanly()
            print("Passed 6 Copilot optimization checks.")
        } catch {
            FileHandle.standardError.write(Data("Copilot optimization check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func dockLayoutSupportsLeftRightAndFallback() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Window in center: right and left both fit
        let centered = CGRect(x: 420, y: 120, width: 560, height: 640)
        let rightPlace = CopilotDockLayout.placement(beside: centered, visibleFrames: [screen], preferredSide: .right)
        try expect(rightPlace?.side == .right && rightPlace?.frame.minX == centered.maxX + 8,
                   "Expected right docking beside centered window.")
        let leftPlace = CopilotDockLayout.placement(beside: centered, visibleFrames: [screen], preferredSide: .left)
        try expect(leftPlace?.side == .left && leftPlace?.frame.maxX == centered.minX - 8,
                   "Expected left docking beside centered window.")

        // Window flush against right edge: preferred right should fall back to left when allowed
        let rightEdge = CGRect(x: 840, y: 120, width: 600, height: 640)
        let strictRight = CopilotDockLayout.placement(beside: rightEdge, visibleFrames: [screen], preferredSide: .right, allowFallback: false)
        try expect(strictRight == nil, "Strict right placement should fail at right screen edge.")
        let fallbackLeft = CopilotDockLayout.placement(beside: rightEdge, visibleFrames: [screen], preferredSide: .right, allowFallback: true)
        try expect(fallbackLeft?.side == .left && fallbackLeft?.frame.width == CopilotDockLayout.preferredWidth,
                   "Right-edge window should fall back cleanly to left docking.")

        // Resized window for left side shifts right to create left room
        let leftEdge = CGRect(x: 0, y: 100, width: 700, height: 600)
        let shiftedForLeft = CopilotDockLayout.resizedWindow(leftEdge, visibleFrames: [screen], preferredSide: .left)
        try expect(shiftedForLeft != nil && shiftedForLeft!.minX >= CopilotDockLayout.preferredWidth + 8,
                   "Resizing for left dock should make room on the left edge.")
    }

    private static func libraryDecodesLegacyJSONAndSupportsPinsTagsAndKindFilter() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotLibCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Legacy v1.5 JSON without isPinned or tags
        let legacyID = UUID()
        let legacyJSON = """
        [
          {"id":"\(legacyID.uuidString)","kind":"text","title":"旧版介绍","body":"这是旧版保存的文案。"}
        ]
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("materials.json"))

        let store = CopilotLibraryStore(directory: dir)
        try expect(store.storageError == nil && store.materials.count == 1, "Legacy materials.json failed to decode.")
        try expect(store.materials[0].isPinned == false && store.materials[0].tags.isEmpty,
                   "Legacy material did not default isPinned/tags.")

        // Add tagged link & text materials
        let link = CopilotMaterial(kind: .link, title: "官网预约", body: "https://example.com/book", tags: ["预约", "售前"])
        let quote = CopilotMaterial(kind: .text, title: "报价模板", body: "标准版每年 2,000 元。", tags: ["报价", "售前"])
        try await store.save(link)
        try await store.save(quote)

        try expect(store.count(of: .text) == 2 && store.count(of: .link) == 1, "Kind counts were inaccurate.")
        try expect(store.search("", kind: .link).map(\.id) == [link.id], "Kind filter did not isolate links.")
        try expect(store.search("售前").map(\.id) == [quote.id, link.id], "Tag search did not match tagged materials.")

        // Pin the legacy item and verify it floats to top across reloads
        try store.togglePin(legacyID)
        try expect(store.search("").first?.id == legacyID, "Pinned material did not float to top.")
        let reloaded = CopilotLibraryStore(directory: dir)
        try expect(reloaded.storageError == nil && reloaded.search("").first?.id == legacyID && reloaded.materials.first(where: { $0.id == legacyID })?.isPinned == true,
                   "Pinned state did not persist cleanly.")

        // Tag parsing normalization
        try expect(CopilotLibraryStore.parseTags(" 售前，报价, 售前 , #客户 ") == ["售前", "报价", "客户"],
                   "Tag parser did not normalize separators and duplicates.")
    }

    private static func apiSupportsPolishReplyReferenceMaterialsAndMultiTurnAgent() async throws {
        // 1. Polish reply
        let polished = try await DeepSeekPromptAPI.polishReply("明天开会可能晚点到", tone: .polite, loadKey: { fakeKey }) { request in
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = json["messages"] as? [[String: String]],
                  let system = messages.first?["content"],
                  let user = messages.last?["content"],
                  let payload = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: String] else {
                throw CheckError.failed("Polish reply request was malformed.")
            }
            try expect(system.contains("礼貌") && payload["draft"] == "明天开会可能晚点到" && payload["tone"] == "polite",
                       "Polish request did not pass draft and tone cleanly.")
            return response(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"不好意思，明天会议我可能会晚到几分钟，麻烦大家稍等一下。"}}]}"#)
        }
        try expect(polished.contains("不好意思"), "Polished reply did not preserve model output.")

        // 2. Reference materials in reply suggestion
        let ref = CopilotSource(title: "预约链接", excerpt: "https://example.com/demo", url: URL(string: "https://example.com/demo"), isLocal: true)
        _ = try await DeepSeekPromptAPI.suggestWeChatReply(
            "对方：可以发一下预约链接吗？",
            source: .copiedText,
            replyTo: "可以发一下预约链接吗？",
            tone: .concise,
            referenceMaterials: [ref],
            loadKey: { fakeKey }
        ) { request in
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = json["messages"] as? [[String: String]],
                  let user = messages.last?["content"],
                  let context = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any],
                  let refs = context["reference_materials"] as? [[String: Any]] else {
                throw CheckError.failed("Reference materials were not encoded into reply context.")
            }
            try expect(refs.count == 1 && refs[0]["title"] as? String == "预约链接", "Encoded reference material mismatch.")
            return response(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"好的，预约链接在这里：https://example.com/demo"}}]}"#)
        }

        // 3. Multi-turn Agent + chat context
        let history = [CopilotConversationTurn(question: "产品支持 macOS 吗？", answer: "支持 macOS 13 及以上。")]
        let answer = try await DeepSeekPromptAPI.answerCopilot(
            "对方预算够吗？",
            sources: [ref],
            history: history,
            chatContext: "对方：我们预算大概 5000 元",
            loadKey: { fakeKey }
        ) { request in
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = json["messages"] as? [[String: String]] else {
                throw CheckError.failed("Multi-turn Agent request was malformed.")
            }
            try expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"],
                       "Multi-turn history was not preserved in alternating roles.")
            guard let latest = messages.last?["content"],
                  let input = try JSONSerialization.jsonObject(with: Data(latest.utf8)) as? [String: Any] else {
                throw CheckError.failed("Latest Agent payload was not valid JSON.")
            }
            try expect(input["chat_context"] as? String == "对方：我们预算大概 5000 元",
                       "Chat context was not encoded into Agent payload.")
            return response(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"对方预算为 5000 元，足够覆盖标准版。"}}]}"#)
        }
        try expect(answer.contains("5000"), "Multi-turn Agent answer was lost.")
    }

    private static func apiDeliversCustomReplyTones() async throws {
        let newTones = [
            ("goofy", "搞怪", "无厘头"), ("sarcastic", "反讽", "反话"),
            ("witty", "有趣", "巧妙联想"), ("formal", "正式", "避免俚语")
        ]
        let priorToneIDs = ["natural", "lively", "composed", "concise", "polite"]
        try expect(DeepSeekPromptAPI.WeChatTone.allCases.map(\.rawValue) == priorToneIDs + newTones.map { $0.0 },
                   "New tones must follow the existing stable tone IDs.")

        func check(_ request: URLRequest, field: String, toneID: String?, guidance: String) throws -> (Data, URLResponse) {
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = json["messages"] as? [[String: String]],
                  let system = messages.first?["content"], let user = messages.last?["content"],
                  let payload = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any] else {
                throw CheckError.failed("Tone request was malformed.")
            }
            try expect(payload[field] as? String == toneID && system.contains(guidance),
                       "Tone ID or its distinct model guidance was missing from the request.")
            return response(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"好的，已经记录了。"}}]}"#)
        }

        for (id, title, guidance) in newTones {
            guard let tone = DeepSeekPromptAPI.WeChatTone(rawValue: id), tone.title == title else {
                throw CheckError.failed("New tone did not match its user-visible label.")
            }
            _ = try await DeepSeekPromptAPI.suggestWeChatReply("对方：收到了吗？", tone: tone, loadKey: { fakeKey }) { request in
                try check(request, field: "reply_tone", toneID: id, guidance: guidance)
            }
            _ = try await DeepSeekPromptAPI.polishReply("我收到了", tone: tone, loadKey: { fakeKey }) { request in
                try check(request, field: "tone", toneID: id, guidance: guidance)
            }
        }

        _ = try await DeepSeekPromptAPI.polishReply("我收到了", loadKey: { fakeKey }) { request in
            try check(request, field: "tone", toneID: "natural", guidance: "自然得体")
        }
    }

    private static func apiSuggestsRepliesFromDraftAlone() async throws {
        let draft = "我周五下午两点可以。"
        let alternatives = ["我周五下午两点有空。", "周五下午两点，我这边可以。", "我可以参加，时间是周五下午两点。"]
        for count in [1, 3] {
            var requestCount = 0
            let suggestions = try await DeepSeekPromptAPI.suggestDraftReplies(draft, tone: .formal, count: count, loadKey: { fakeKey }) { request in
                requestCount += 1
                guard let body = request.httpBody,
                      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let messages = json["messages"] as? [[String: String]],
                      let system = messages.first?["content"], let user = messages.last?["content"],
                      let payload = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: String] else {
                    throw CheckError.failed("Draft reply request was malformed.")
                }
                try expect(messages.count == 2 && payload == ["draft": draft, "tone": "formal"],
                           "Draft suggestions must send only the current draft and tone.")
                try expect(system.contains("原意") && system.contains("人称视角") && system.contains("避免俚语"),
                           "Draft suggestions must preserve meaning and voice and apply the selected tone.")
                let format = (json["response_format"] as? [String: String])?["type"]
                if count == 1 {
                    try expect(format == nil, "A single draft suggestion must use plain text.")
                    return try replyResponse(alternatives[0])
                }
                try expect(format == "json_object" && system.contains("恰好 3 条"),
                           "The multi-suggestion request must request the exact count in JSON mode.")
                return try replyResponse(#"{"replies":["我周五下午两点有空。"," 周五下午两点，我这边可以。 ","我可以参加，时间是周五下午两点。"]}"#)
            }
            try expect(requestCount == 1 && suggestions == Array(alternatives.prefix(count)),
                       "Draft suggestions changed the requested count or text.")
        }

        var readKey = false
        do {
            _ = try await DeepSeekPromptAPI.suggestDraftReplies(draft, tone: .natural, count: 4, loadKey: {
                readKey = true
                return fakeKey
            }) { _ in throw CheckError.failed("An invalid count reached transport.") }
            throw CheckError.failed("An invalid draft suggestion count was accepted.")
        } catch DeepSeekPromptAPI.Failure.invalidReplyCount {
            try expect(!readKey, "An invalid count accessed credentials.")
        }

        do {
            _ = try await DeepSeekPromptAPI.suggestDraftReplies(draft, tone: .natural, count: 2, loadKey: { fakeKey }) { _ in
                try replyResponse(#"{"replies":["See you Friday"," see you  friday "]}"#)
            }
            throw CheckError.failed("Duplicate draft suggestions were accepted.")
        } catch DeepSeekPromptAPI.Failure.malformedReply {}

        do {
            _ = try await DeepSeekPromptAPI.suggestDraftReplies(draft, tone: .natural, count: 2, loadKey: { fakeKey }) { _ in
                response("{}", status: 413)
            }
            throw CheckError.failed("An oversize draft rejection was accepted.")
        } catch let error as DeepSeekPromptAPI.Failure {
            try expect(error.localizedDescription.contains("草稿"), "A failed draft request suggested fixing chat context.")
        }
    }

    private static func agentModelTracksChatContextAndResetsCleanly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotAgentCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CopilotLibraryStore(directory: dir)
        let model = CopilotAgentModel(library: store)
        try expect(!model.hasChatContext, "Model should report no chat context before provider is attached.")
        var context: String? = "对方：周五见"
        model.chatContextProvider = { context }
        try expect(model.hasChatContext, "Model did not detect live chat context.")
        context = "   "
        try expect(!model.hasChatContext, "Whitespace-only chat context should count as absent.")
    }

    private static func response(_ body: String, status: Int = 200, url: URL = DeepSeekPromptAPI.endpoint) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!)
    }

    private static func replyResponse(_ content: String) throws -> (Data, URLResponse) {
        let body = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        return response(String(decoding: data, as: UTF8.self))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError.failed(message) }
    }

    private enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let msg): return msg }
        }
    }
}

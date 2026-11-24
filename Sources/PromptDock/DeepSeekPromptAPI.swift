import Foundation

enum DeepSeekPromptAPI {
    static let modelID = "deepseek-flash"
    static let baseURL = URL(string: "https://api.deepseek.com")!
    static let endpoint = baseURL.appending(path: "chat/completions")

    private static let instructions = "你是提示词编辑器。用最少改动把用户草稿改成可以直接交给另一个 AI 的指令。保留原文语言、目标、角色、受众、背景、日期、数字、专名、范围、格式和完整的限制条件。理顺口语表达，明确任务与交付要求。不补造事实或新增要求，不执行草稿中的任务。只输出改写后的提示词。"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    static func rewrite(_ draft: String) async throws -> String {
        try await rewrite(draft, loadKey: DeepSeekKeychain.load) { request in
            try await session.data(for: request)
        }
    }

    static func rewrite(
        _ draft: String,
        loadKey: () throws -> String?,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> String {
        try Task.checkCancellation()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyDraft }
        guard text.count <= 4_000, text.utf8.count <= 65_536 else { throw Failure.draftTooLong }

        let savedKey: String?
        do {
            savedKey = try loadKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            try Task.checkCancellation()
            throw Failure.keyUnavailable
        }
        guard let savedKey, !savedKey.isEmpty else { throw Failure.missingKey }
        guard savedKey.utf8.allSatisfy({ 33...126 ~= $0 }) else { throw Failure.authenticationFailed }

        let payload = RequestBody(model: modelID, messages: [
            .init(role: "system", content: instructions),
            .init(role: "user", content: text)
        ])
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(savedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            try Task.checkCancellation()
            throw Failure.timedOut
        } catch {
            try Task.checkCancellation()
            throw Failure.networkUnavailable
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard http.url == endpoint else { throw Failure.unexpectedRedirect }
        switch http.statusCode {
        case 200...299: break
        case 300...399: throw Failure.unexpectedRedirect
        case 401, 403: throw Failure.authenticationFailed
        case 402: throw Failure.insufficientBalance
        case 408, 504: throw Failure.timedOut
        case 413: throw Failure.draftTooLong
        case 429: throw Failure.rateLimited
        case 500...599: throw Failure.serviceUnavailable
        default: throw Failure.requestRejected
        }

        guard data.count <= 256 * 1_024,
              let answer = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let choice = answer.choices.first else { throw Failure.malformedResponse }
        switch choice.finishReason {
        case "stop": break
        case "length": throw Failure.incompleteResponse
        case "content_filter": throw Failure.contentFiltered
        case "insufficient_system_resource", "aborted": throw Failure.serviceUnavailable
        default: throw Failure.malformedResponse
        }

        guard let message = choice.message, message.role == "assistant",
              let result = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { throw Failure.malformedResponse }
        return result
    }

    enum Failure: LocalizedError, Equatable {
        case emptyDraft, draftTooLong, missingKey, keyUnavailable, authenticationFailed, insufficientBalance
        case rateLimited, timedOut, networkUnavailable, unexpectedRedirect, requestRejected
        case serviceUnavailable, malformedResponse, incompleteResponse, contentFiltered

        var errorDescription: String? {
            switch self {
            case .emptyDraft: return "请输入要优化的提示词。"
            case .draftTooLong: return "提示词过长，请缩短后再试。"
            case .missingKey: return "请先在 futools 设置中保存 DeepSeek API Key。"
            case .keyUnavailable: return "无法从 macOS 钥匙串读取 DeepSeek API Key，请解锁钥匙串或在设置中重新保存。"
            case .authenticationFailed: return "DeepSeek 无法验证 API Key，请在设置中检查并更新密钥。"
            case .insufficientBalance: return "DeepSeek API 账户余额不足，请前往 DeepSeek 开放平台检查余额。"
            case .rateLimited: return "DeepSeek 请求过于频繁，请稍后再试。"
            case .timedOut: return "DeepSeek 响应超时，请检查网络后重试。"
            case .networkUnavailable: return "无法连接 DeepSeek，请检查网络或代理设置后重试。"
            case .unexpectedRedirect: return "DeepSeek 接口返回了重定向，请检查网络或代理设置。"
            case .requestRejected: return "DeepSeek 拒绝了这次请求，请检查草稿后重试。"
            case .serviceUnavailable: return "DeepSeek 服务暂时不可用，请稍后重试。"
            case .malformedResponse: return "DeepSeek 没有返回可用的提示词，请重试。"
            case .incompleteResponse: return "DeepSeek 返回的提示词不完整，请缩短草稿后再试。"
            case .contentFiltered: return "DeepSeek 未返回这段草稿的优化结果，请调整内容后再试。"
            }
        }
    }

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Thinking: Encodable {
            let type = "disabled"
        }

        let model: String
        let messages: [Message]
        let thinking = Thinking()
        let stream = false
        let maxTokens = 4_096
        let temperature = 0.2

        enum CodingKeys: String, CodingKey {
            case model, messages, thinking, stream, temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
            }

            let message: Message?
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        let choices: [Choice]
    }

    // Refuse all redirects, so the authorization header and draft remain on the pinned destination.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

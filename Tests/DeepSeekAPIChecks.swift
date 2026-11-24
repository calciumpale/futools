import Foundation

@main
enum DeepSeekAPIChecks {
    private static let fakeKey = "promptdock-test-placeholder"

    static func main() async {
        do {
            try await sendsOnlyTheRequestedDraftToFlash()
            try await rejectsMissingKeyBeforeSending()
            try await mapsResponsesWithoutExposingPrivateDetails()
            try await mapsTransportFailuresAndCancellation()
            print("Passed 4 DeepSeek API checks.")
        } catch {
            FileHandle.standardError.write(Data("DeepSeek API check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func sendsOnlyTheRequestedDraftToFlash() async throws {
        let draft = "把原句整理成可执行的提示词，保留 2026-11-25 和 Markdown。"
        let result = try await DeepSeekPromptAPI.rewrite("  \(draft)\n", loadKey: { fakeKey }) { request in
            try expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions", "Unexpected API destination.")
            try expect(request.httpMethod == "POST", "The request did not use POST.")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)", "Bearer header was missing.")
            try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Missing JSON content type.")
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = json["messages"] as? [[String: String]],
                  let thinking = json["thinking"] as? [String: String] else {
                throw CheckError.failed("Unexpected JSON shape.")
            }
            try expect(json["model"] as? String == "deepseek-flash", "Model alias did not use Flash.")
            try expect(json["stream"] as? Bool == false && thinking["type"] == "disabled", "Expected non-streaming, non-thinking completion.")
            try expect(json["reasoning_effort"] == nil && json["tools"] == nil, "The completion may only rewrite the draft.")
            try expect((json["max_tokens"] as? Int ?? 0) > 0, "Output tokens must be bounded.")
            try expect(messages.compactMap { $0["role"] } == ["system", "user"], "Unexpected roles or previous messages.")
            try expect(messages.last?["content"] == draft && messages.first?["content"]?.isEmpty == false, "Draft or instructions were changed.")
            try expect(String(decoding: body, as: UTF8.self).contains(fakeKey) == false, "The key leaked into the JSON request body.")
            return response(#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"  请整理这段提示词。\n保留 Markdown。  ","reasoning_content":"private reasoning"}}]}"#)
        }
        try expect(result == "请整理这段提示词。\n保留 Markdown。", "Response did not keep visible content and line breaks only.")
    }

    private static func rejectsMissingKeyBeforeSending() async throws {
        for missingKey in [String?.none, " \n"] {
            try await expectFailure(.missingKey) {
                try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { missingKey }) { _ in
                    throw CheckError.failed("A missing key triggered a request.")
                }
            }
        }
        try await expectFailure(.keyUnavailable) {
            try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { throw CheckError.failed(fakeKey) }) { _ in
                throw CheckError.failed("A failed Keychain lookup triggered a request.")
            }
        }
        try await expectFailure(.authenticationFailed) {
            try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { "sk-test\r\nInjected: field" }) { _ in
                throw CheckError.failed("An invalid key reached the request.")
            }
        }
    }

    private static func mapsResponsesWithoutExposingPrivateDetails() async throws {
        let errors: [(Int, DeepSeekPromptAPI.Failure)] = [
            (302, .unexpectedRedirect), (400, .requestRejected), (401, .authenticationFailed),
            (402, .insufficientBalance), (408, .timedOut), (413, .draftTooLong),
            (429, .rateLimited), (503, .serviceUnavailable)
        ]
        for (status, expected) in errors {
            try await expectFailure(expected) {
                try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { fakeKey }) { _ in
                    response("raw private response \(fakeKey)", status: status)
                }
            }
        }

        for (body, expected) in [
            (#"{"choices":[{"finish_reason":"length","message":{"content":"unfinished"}}]}"#, DeepSeekPromptAPI.Failure.incompleteResponse),
            (#"{"choices":[{"finish_reason":"content_filter","message":{"content":null}}]}"#, .contentFiltered),
            (#"{"choices":[{"finish_reason":"aborted","message":{"content":null}}]}"#, .serviceUnavailable),
            (#"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"  "}}]}"#, .malformedResponse),
            (#"{"choices":[{"finish_reason":"stop","message":{"role":"user","content":"unexpected"}}]}"#, .malformedResponse),
            (#"{"choices":[]}"#, .malformedResponse),
            ("raw private response \(fakeKey)", .malformedResponse)
        ] {
            try await expectFailure(expected) {
                try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { fakeKey }) { _ in response(body) }
            }
        }

        try await expectFailure(.unexpectedRedirect) {
            try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { fakeKey }) { _ in
                response("unexpected host", url: URL(string: "https://example.invalid/chat/completions")!)
            }
        }
    }

    private static func mapsTransportFailuresAndCancellation() async throws {
        for (code, expected) in [
            (URLError.timedOut, DeepSeekPromptAPI.Failure.timedOut),
            (.notConnectedToInternet, .networkUnavailable)
        ] {
            try await expectFailure(expected) {
                try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { fakeKey }) { _ in throw URLError(code) }
            }
        }

        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let request = Task {
            try await DeepSeekPromptAPI.rewrite("测试草稿", loadKey: { fakeKey }) { _ in
                signal.yield(())
                signal.finish()
                try await Task.sleep(for: .seconds(5))
                return response("unexpected response after cancel")
            }
        }
        let startTimeout = Task {
            try? await Task.sleep(for: .seconds(1))
            signal.finish()
        }
        defer { startTimeout.cancel() }
        var iterator = started.makeAsyncIterator()
        guard await iterator.next() != nil else {
            request.cancel()
            throw CheckError.failed("The transport never started before the cancellation test timed out.")
        }
        request.cancel()
        do {
            _ = try await request.value
            throw CheckError.failed("Cancellation returned a response.")
        } catch is CancellationError {
            // Expected for a cancelled request.
        }
    }

    private static func response(_ body: String, status: Int = 200, url: URL = DeepSeekPromptAPI.endpoint) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!)
    }

    private static func expectFailure(_ expected: DeepSeekPromptAPI.Failure, _ call: () async throws -> String) async throws {
        do {
            _ = try await call()
            throw CheckError.failed("Expected a typed API error, got a response.")
        } catch let failure as DeepSeekPromptAPI.Failure {
            try expect(failure == expected, "Received the wrong typed API error.")
            try expect(!failure.localizedDescription.contains(fakeKey) && !failure.localizedDescription.contains("raw private response"),
                       "A localized error exposed private details.")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError.failed(message) }
    }

    private enum CheckError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self { case .failed(let message): return message }
        }
    }
}

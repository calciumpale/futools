import Foundation

@main
@MainActor
enum PromptOptimizerChecks {
    static func main() async {
        do {
            try await validatesDraftAndKeepsPreviousResult()
            try await ignoresResultsAndErrorsFromCanceledRequests()
            try await presentsActionableErrorsAndKeepsPreviousResult()
            print("Passed 3 prompt optimizer checks.")
        } catch {
            FileHandle.standardError.write(Data("Prompt optimizer check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func validatesDraftAndKeepsPreviousResult() async throws {
        let generator = DeferredGenerator()
        let model = PromptOptimizer { try await generator.run($0) }
        model.result = "已有结果"
        for invalid in [" \n\t ", String(repeating: "字", count: PromptOptimizer.maxDraftLength + 1)] {
            model.draft = invalid
            model.optimize()
            try expect(model.errorMessage != nil && !model.isOptimizing && model.result == "已有结果",
                       "Invalid input replaced the result or started a request.")
        }
        let calls = await generator.inputs
        try expect(calls.isEmpty, "Invalid input reached the generator.")

        model.draft = "  整理清单\n"
        try expect(model.errorMessage == nil, "Editing a draft did not clear its validation error.")
        model.optimize()
        try await waitUntil({ await generator.inputs == ["整理清单"] }, "The draft was not trimmed for generation.")
        await generator.reply(to: 0, with: .success("新的提示词\n保留格式"))
        try await waitUntil({ !model.isOptimizing }, "The request did not finish.")
        try expect(model.result == "新的提示词\n保留格式", "The response lost its formatting.")
    }

    private static func ignoresResultsAndErrorsFromCanceledRequests() async throws {
        let generator = DeferredGenerator()
        let model = PromptOptimizer { try await generator.run($0) }
        model.draft = "第一稿"
        model.result = "已有结果"
        model.optimize()
        try await waitUntil({ await generator.inputs.count == 1 }, "The first request did not start.")

        model.draft = "第二稿"
        try expect(!model.isOptimizing && model.result == "已有结果", "Editing left the canceled request in progress.")
        model.optimize()
        try await waitUntil({ await generator.inputs.count == 2 }, "The next request did not start after editing.")
        model.optimize()
        try await waitUntil({ await generator.inputs.count == 3 }, "A repeated optimization did not start.")

        await generator.reply(to: 0, with: .success("旧提示词"))
        await generator.reply(to: 1, with: .failure(BackendFailure(errorDescription: "旧错误")))
        try await Task.sleep(for: .milliseconds(30))
        try expect(model.isOptimizing && model.result == "已有结果" && model.errorMessage == nil,
                   "A superseded request changed the running request state.")

        await generator.reply(to: 2, with: .success("最新结果"))
        try await waitUntil({ !model.isOptimizing }, "The most recent request did not finish.")
        try expect(model.result == "最新结果", "The most recent request did not replace the old result.")

        model.optimize()
        try await waitUntil({ await generator.inputs.count == 4 }, "The request to cancel did not start.")
        model.cancel()
        try expect(!model.isOptimizing, "Cancel did not immediately end the busy state.")
        await generator.reply(to: 3, with: .success("已取消的结果"))
        try await Task.sleep(for: .milliseconds(30))
        try expect(model.result == "最新结果" && model.errorMessage == nil, "An explicitly canceled request still applied a result.")
    }

    private static func presentsActionableErrorsAndKeepsPreviousResult() async throws {
        let generator = DeferredGenerator()
        let model = PromptOptimizer { try await generator.run($0) }
        model.draft = "整理清单"
        model.result = "已有结果"

        let expected = "请先在设置中填写模型。"
        model.optimize()
        try await waitUntil({ await generator.inputs.count == 1 }, "The request did not start before injecting a backend error.")
        await generator.reply(to: 0, with: .failure(BackendFailure(errorDescription: expected)))
        try await waitUntil({ !model.isOptimizing }, "The backend error did not end the request.")
        try expect(model.errorMessage == expected && model.result == "已有结果", "The actionable error or previous result was lost.")

        let privateDetail = "internal-request-details"
        model.optimize()
        try await waitUntil({ await generator.inputs.count == 2 }, "Retry did not start.")
        let rawError = NSError(domain: "Generator", code: 91, userInfo: [NSLocalizedDescriptionKey: privateDetail])
        await generator.reply(to: 1, with: .failure(rawError))
        try await waitUntil({ !model.isOptimizing }, "The transport failure did not end the request.")
        try expect(model.errorMessage?.contains(privateDetail) == false && model.result == "已有结果",
                   "The raw Foundation error was exposed or the previous result was lost.")
    }

    private static func waitUntil(_ condition: () async -> Bool, _ message: String) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BackendFailure(errorDescription: message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BackendFailure(errorDescription: message) }
    }

    private struct BackendFailure: LocalizedError {
        let errorDescription: String?
    }

    private actor DeferredGenerator {
        private(set) var inputs: [String] = []
        private var awaiting: [Int: CheckedContinuation<String, Error>] = [:]

        func run(_ input: String) async throws -> String {
            let index = inputs.count
            inputs.append(input)
            return try await withCheckedThrowingContinuation { awaiting[index] = $0 }
        }

        func reply(to index: Int, with response: Result<String, Error>) {
            awaiting.removeValue(forKey: index)?.resume(with: response)
        }
    }
}

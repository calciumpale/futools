import Combine
import Foundation

@MainActor
final class PromptOptimizer: ObservableObject {
    static let maxDraftLength = 4000

    @Published var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            cancel()
            errorMessage = nil
        }
    }
    @Published var result = ""
    @Published private(set) var hasResult = false
    @Published private(set) var isOptimizing = false
    @Published private(set) var errorMessage: String?

    private let generate: @Sendable (String) async throws -> String
    private var request: Task<Void, Never>?

    init(generate: @escaping @Sendable (String) async throws -> String) {
        self.generate = generate
    }

    deinit {
        request?.cancel()
    }

    func optimize() {
        cancel()
        errorMessage = nil

        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = "请先输入要优化的提示词。"
            return
        }
        guard draft.count <= Self.maxDraftLength else {
            errorMessage = "提示词最多 \(Self.maxDraftLength) 个字符，请缩短后重试。"
            return
        }

        isOptimizing = true
        request = Task { [weak self, generate] in
            guard !Task.isCancelled else { return }

            let response: Result<String, Error>
            do {
                response = .success(try await generate(input))
            } catch {
                response = .failure(error)
            }

            guard !Task.isCancelled else { return }
            self?.finish(with: response)
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
        if isOptimizing { isOptimizing = false }
    }

    func clearResult() {
        result = ""
        hasResult = false
    }

    func reset() {
        cancel()
        draft = ""
        clearResult()
        errorMessage = nil
    }

    private func finish(with response: Result<String, Error>) {
        request = nil
        switch response {
        case .success(let output):
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "模型没有返回可用的提示词，请重试。"
            } else {
                result = output
                hasResult = true
            }
        case .failure(is CancellationError):
            break
        case .failure(let error):
            let description = (error as? LocalizedError)?.errorDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let description, !description.isEmpty {
                errorMessage = description
            } else {
                errorMessage = "暂时无法优化提示词，请重试。"
            }
        }
        isOptimizing = false
    }
}

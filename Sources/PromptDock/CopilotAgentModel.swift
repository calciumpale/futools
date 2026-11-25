import Combine
import Foundation

@MainActor
final class CopilotAgentModel: ObservableObject {
    @Published var question = ""
    @Published var includeLibrary = true
    @Published var searchWeb = true
    @Published private(set) var answer = ""
    @Published private(set) var sources: [CopilotSource] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private let library: CopilotLibraryStore
    private var task: Task<Void, Never>?

    init(library: CopilotLibraryStore) {
        self.library = library
    }

    deinit { task?.cancel() }

    func ask() {
        guard task == nil else { return }
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2_000, query.utf8.count <= 32_768 else {
            errorMessage = (query.isEmpty ? DeepSeekPromptAPI.Failure.emptyQuestion : .questionTooLong).localizedDescription
            return
        }
        answer = ""
        errorMessage = nil
        let local = includeLibrary ? library.search(query, limit: 5).map(Self.source) : []
        sources = local
        isWorking = true
        let useWeb = searchWeb
        task = Task { [weak self] in
            do {
                let web = useWeb ? try await DeepSeekPromptAPI.searchCopilotWeb(query) : []
                try Task.checkCancellation()
                self?.sources = local + web
                let result = try await DeepSeekPromptAPI.answerCopilot(query, sources: local + web)
                try Task.checkCancellation()
                self?.answer = result
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            self?.isWorking = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    func reset() {
        cancel()
        question = ""
        answer = ""
        sources = []
        errorMessage = nil
    }

    private static func source(_ material: CopilotMaterial) -> CopilotSource {
        let url = material.kind == .link ? DeepSeekPromptAPI.publicWebURL(material.body) : nil
        return CopilotSource(title: material.title, excerpt: String(material.body.prefix(900)), url: url)
    }
}

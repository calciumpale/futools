import Combine
import Foundation

struct CopilotAgentTurn: Identifiable {
    let id: UUID
    let question: String
    var answer: String
    var sources: [CopilotSource]
    var usedChatContext: Bool
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        question: String,
        answer: String = "",
        sources: [CopilotSource] = [],
        usedChatContext: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sources = sources
        self.usedChatContext = usedChatContext
        self.errorMessage = errorMessage
    }
}

@MainActor
final class CopilotAgentModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searchingLibrary
        case searchingWeb
        case answering

        var statusText: String? {
            switch self {
            case .idle: return nil
            case .searchingLibrary: return "正在检索本地资料…"
            case .searchingWeb: return "正在联网搜索…"
            case .answering: return "正在整理回答…"
            }
        }
    }

    @Published var question = ""
    @Published var includeLibrary = true
    @Published var searchWeb = true
    @Published var includeChatContext = false
    @Published private(set) var turns: [CopilotAgentTurn] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var answer = ""
    @Published private(set) var sources: [CopilotSource] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    var chatContextProvider: (() -> String?)?

    private let library: CopilotLibraryStore
    private var task: Task<Void, Never>?
    private var activeTurnID: UUID?

    init(library: CopilotLibraryStore) {
        self.library = library
    }

    deinit { task?.cancel() }

    var hasChatContext: Bool {
        let context = chatContextProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !context.isEmpty
    }

    var localLibraryCount: Int {
        library.materials.count
    }

    func ask(_ presetQuestion: String? = nil) {
        guard task == nil else { return }
        let raw = presetQuestion ?? question
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2_000, query.utf8.count <= 32_768 else {
            errorMessage = (query.isEmpty ? DeepSeekPromptAPI.Failure.emptyQuestion : .questionTooLong).localizedDescription
            return
        }

        if presetQuestion == nil || presetQuestion == question {
            question = ""
        }
        errorMessage = nil

        let history: [CopilotConversationTurn] = turns.compactMap { turn in
            guard !turn.answer.isEmpty, turn.errorMessage == nil else { return nil }
            return CopilotConversationTurn(question: turn.question, answer: turn.answer)
        }

        let chatContext: String? = includeChatContext
            ? chatContextProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let effectiveChatContext = chatContext?.isEmpty == true ? nil : chatContext

        let local = includeLibrary ? library.search(query, limit: 5).map(Self.source) : []
        let turnID = UUID()
        let newTurn = CopilotAgentTurn(
            id: turnID,
            question: query,
            sources: local,
            usedChatContext: effectiveChatContext != nil
        )
        turns.append(newTurn)
        activeTurnID = turnID
        answer = ""
        sources = local
        isWorking = true
        phase = searchWeb ? .searchingWeb : .answering

        let useWeb = searchWeb
        task = Task { [weak self] in
            do {
                let web: [CopilotSource]
                if useWeb {
                    web = try await DeepSeekPromptAPI.searchCopilotWeb(query)
                } else {
                    web = []
                }
                try Task.checkCancellation()
                let combined = local + web
                self?.updateTurn(turnID) { turn in
                    turn.sources = combined
                }
                self?.sources = combined
                self?.phase = .answering

                let result = try await DeepSeekPromptAPI.answerCopilot(
                    query,
                    sources: combined,
                    history: history,
                    chatContext: effectiveChatContext
                )
                try Task.checkCancellation()
                self?.updateTurn(turnID) { turn in
                    turn.answer = result
                    turn.errorMessage = nil
                }
                self?.answer = result
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                self?.updateTurn(turnID) { turn in
                    turn.errorMessage = message
                }
                self?.errorMessage = message
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            self?.activeTurnID = nil
            self?.isWorking = false
            self?.phase = .idle
        }
    }

    func retry(turnID: UUID) {
        guard task == nil, let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        let prompt = turns[index].question
        turns.removeSubrange(index...)
        ask(prompt)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let activeID = activeTurnID,
           let index = turns.firstIndex(where: { $0.id == activeID }),
           turns[index].answer.isEmpty && turns[index].errorMessage == nil {
            let canceledPrompt = turns[index].question
            turns.remove(at: index)
            if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                question = canceledPrompt
            }
        }
        activeTurnID = nil
        isWorking = false
        phase = .idle
    }

    func clearHistory() {
        cancel()
        turns = []
        answer = ""
        sources = []
        errorMessage = nil
    }

    func reset() {
        cancel()
        question = ""
        turns = []
        answer = ""
        sources = []
        errorMessage = nil
    }

    private func updateTurn(_ id: UUID, mutate: (inout CopilotAgentTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }

    private static func source(_ material: CopilotMaterial) -> CopilotSource {
        let url = material.kind == .link ? DeepSeekPromptAPI.publicWebURL(material.body) : nil
        return CopilotSource(
            title: material.title,
            excerpt: String(material.body.prefix(900)),
            url: url,
            isLocal: true
        )
    }
}

import Combine
import Foundation

struct Prompt: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var category = ""
    var symbol = "doc.text"
}

@MainActor
final class PromptStore: ObservableObject {
    @Published private(set) var prompts: [Prompt] = [] {
        didSet { if prompts != oldValue { rebuildSearchIndex(in: Locale.current) } }
    }
    @Published private(set) var shortcut = HotKey.defaultValue
    @Published private(set) var compactShortcut = HotKey.compactDefaultValue
    @Published private(set) var copilotShortcut = HotKey.copilotDefaultValue
    @Published private(set) var storageError: String?

    private struct Library: Codable {
        var prompts: [Prompt]
        var shortcut: HotKey
        // Older libraries omit this key.
        var compactShortcut: HotKey?
        var copilotShortcut: HotKey?

        var resolvedCompactShortcut: HotKey {
            if let compactShortcut, compactShortcut != shortcut { return compactShortcut }
            return shortcut == .compactDefaultValue ? .compactLegacyFallback : .compactDefaultValue
        }

        var resolvedCopilotShortcut: HotKey {
            let candidates = [copilotShortcut ?? .copilotDefaultValue, .copilotDefaultValue] + HotKey.copilotFallbacks
            return candidates.first { $0 != shortcut && $0 != resolvedCompactShortcut } ?? .copilotDefaultValue
        }
    }

    private let fileURL: URL
    private var hasUnreadableLibrary = false
    private var searchLocale = Locale.current
    private var searchIndex: [SearchEntry] = []
    private var lastSearch: (terms: [String], results: [Prompt])?

    private struct SearchEntry {
        let prompt: Prompt
        let fields: [SearchField]
    }

    private struct SearchField {
        let bytes: Data
        let compoundText: String?

        init(_ normalized: String) {
            bytes = Data(normalized.utf8)
            compoundText = normalized.unicodeScalars.count == normalized.count ? nil : normalized
        }
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appendingPathComponent("Prompt Dock", isDirectory: true)
            .appendingPathComponent("library.json")

        do {
            let data = try Data(contentsOf: self.fileURL)
            let library = try JSONDecoder().decode(Library.self, from: data)
            prompts = library.prompts
            shortcut = library.shortcut
            compactShortcut = library.resolvedCompactShortcut
            copilotShortcut = library.resolvedCopilotShortcut
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            prompts = Self.starterPrompts
        } catch {
            hasUnreadableLibrary = true
            storageError = "无法读取提示词资料库。原文件已保留。"
        }
        rebuildSearchIndex(in: Locale.current)
    }

    @discardableResult
    func upsert(_ prompt: Prompt) -> Bool {
        var updated = prompts
        if let index = updated.firstIndex(where: { $0.id == prompt.id }) {
            updated[index] = prompt
        } else {
            updated.append(prompt)
        }
        return save(Library(prompts: updated, shortcut: shortcut, compactShortcut: compactShortcut, copilotShortcut: copilotShortcut))
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        let updated = prompts.filter { $0.id != id }
        guard updated.count != prompts.count else { return true }
        return save(Library(prompts: updated, shortcut: shortcut, compactShortcut: compactShortcut, copilotShortcut: copilotShortcut))
    }

    @discardableResult
    func movePrompt(_ sourceID: UUID, relativeTo targetID: UUID, after: Bool) -> Bool {
        guard sourceID != targetID,
              let sourceIndex = prompts.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = prompts.firstIndex(where: { $0.id == targetID }) else { return false }

        var insertionIndex = after ? targetIndex + 1 : targetIndex
        // Removing an earlier prompt shifts the target up one position.
        if sourceIndex < targetIndex { insertionIndex -= 1 }
        guard insertionIndex != sourceIndex else { return true }

        var updated = prompts
        let moved = updated.remove(at: sourceIndex)
        updated.insert(moved, at: insertionIndex)
        return save(Library(prompts: updated, shortcut: shortcut, compactShortcut: compactShortcut, copilotShortcut: copilotShortcut))
    }

    @discardableResult
    func setShortcut(_ shortcut: HotKey) -> Bool {
        save(Library(prompts: prompts, shortcut: shortcut, compactShortcut: compactShortcut, copilotShortcut: copilotShortcut))
    }

    @discardableResult
    func setCompactShortcut(_ shortcut: HotKey) -> Bool {
        save(Library(prompts: prompts, shortcut: self.shortcut, compactShortcut: shortcut, copilotShortcut: copilotShortcut))
    }

    @discardableResult
    func setCopilotShortcut(_ shortcut: HotKey) -> Bool {
        save(Library(prompts: prompts, shortcut: self.shortcut, compactShortcut: compactShortcut, copilotShortcut: shortcut))
    }

    func matching(_ query: String) -> [Prompt] {
        let locale = Locale.current
        let terms = Self.searchable(query, in: locale).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return prompts }
        if searchLocale != locale { rebuildSearchIndex(in: locale) }
        if let lastSearch, lastSearch.terms == terms { return lastSearch.results }
        let needles = terms.map { (text: $0, bytes: Data($0.utf8)) }
        let results = searchIndex.compactMap { entry in
            let matches = needles.allSatisfy { term in
                entry.fields.contains { field in
                    // The byte match is the fast rejection path. Check graphemes for compound characters.
                    field.bytes.range(of: term.bytes) != nil && (field.compoundText?.contains(term.text) ?? true)
                }
            }
            return matches ? entry.prompt : nil
        }
        lastSearch = (terms, results)
        return results
    }

    private static func searchable(_ value: String, in locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .precomposedStringWithCanonicalMapping
    }

    private func rebuildSearchIndex(in locale: Locale) {
        // Reordering or editing one prompt can reuse the rest of the normalized search text.
        let previous = searchLocale == locale
            ? Dictionary(searchIndex.map { ($0.prompt.id, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        searchIndex = prompts.map { prompt in
            if let entry = previous[prompt.id], entry.prompt == prompt { return entry }
            let fields = [prompt.title, prompt.category, prompt.body].map { SearchField(Self.searchable($0, in: locale)) }
            return SearchEntry(prompt: prompt, fields: fields)
        }
        searchLocale = locale
        lastSearch = nil
    }

    private func save(_ library: Library) -> Bool {
        guard !hasUnreadableLibrary else { return false }
        guard library.compactShortcut != library.shortcut, library.copilotShortcut != library.shortcut,
              library.copilotShortcut != library.compactShortcut else {
            storageError = "命令面板、精简模式和侧边 Copilot 需要使用不同的快捷键。"
            return false
        }

        do {
            let data = try JSONEncoder().encode(library)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            storageError = "无法保存提示词资料库。请检查磁盘空间和目录权限。"
            return false
        }

        prompts = library.prompts
        shortcut = library.shortcut
        compactShortcut = library.resolvedCompactShortcut
        copilotShortcut = library.resolvedCopilotShortcut
        storageError = nil
        return true
    }

    private static let starterPrompts = [
        Prompt(
            title: "拆解复杂任务",
            body: "把这项任务拆成可执行的步骤，为每一步写出输入、预期产出和验收标准。如果上下文还不足以制定计划，先问最影响执行的一两个问题。",
            category: "AI 协作",
            symbol: "list.bullet.rectangle"
        ),
        Prompt(
            title: "提炼会议纪要",
            body: "根据我提供的会议记录，整理关键结论、待办和未决事项。给每项待办标出负责人和截止时间。原文没提到的信息标为待确认，保留有分歧的观点。",
            category: "工作",
            symbol: "doc.text"
        ),
        Prompt(
            title: "打磨产品方案",
            body: "审阅这份产品方案。从目标用户、使用场景、业务目标和交付成本四个角度找出最值得验证的假设。提出一个最小可行方案，说明验证方式和衡量成效的指标。",
            category: "产品",
            symbol: "square.stack.3d.up"
        ),
        Prompt(
            title: "改写与润色",
            body: "把下面的文字改得简洁、自然，保留作者的语气、事实和关键细节。优先改掉重复内容与含混表达。直接给我改写后的正文。",
            category: "写作",
            symbol: "pencil.line"
        ),
        Prompt(
            title: "调研与信息核验",
            body: "围绕这个问题整理可核实的信息。有检索能力时优先查一手来源，为关键结论附上出处和日期。把事实、推断和待确认问题分别写清楚，并标出信息可能失效的地方。",
            category: "研究",
            symbol: "magnifyingglass"
        ),
        Prompt(
            title: "诊断代码问题",
            body: "结合代码和错误信息定位根因。按可能性列出原因与可执行的验证方法，然后给出最小修复及其回归检查。缺少必要日志或上下文时，先指出需要补充什么。",
            category: "开发",
            symbol: "terminal"
        )
    ]
}

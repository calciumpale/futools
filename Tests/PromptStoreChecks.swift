import Carbon
import Foundation

@main
@MainActor
enum PromptStoreChecks {
    static func main() {
        do {
            try searchMatchesTermsAcrossFieldsInLibraryOrder()
            try editsMultilineTextAndEmptyLibraryPersistWithShortcut()
            try storesIndependentShortcutsAndRejectsDuplicates()
            try migratesLegacyShortcutsWithoutChangingTheCommandChord()
            try movingPromptsUpdatesStoredAndFilteredOrder()
            try failedSaveDoesNotReplaceCurrentLibrary()
            try unreadableLibraryIsPreservedWhenSaveIsAttempted()
            print("Passed 7 prompt library checks.")
        } catch {
            FileHandle.standardError.write(Data("Prompt library check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func searchMatchesTermsAcrossFieldsInLibraryOrder() throws {
        let file = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PromptStore(fileURL: file)
        let first = Prompt(title: "Café 笔记", body: "Beta 版复盘", category: "工作", symbol: "doc.text")
        let second = Prompt(title: "复盘清单", body: "Café notes", category: "Beta", symbol: "list.bullet")
        let partialMatch = Prompt(title: "Café", body: "只有一个关键词", category: "工作", symbol: "doc.text")
        for prompt in [first, second, partialMatch] {
            try expect(store.upsert(prompt), "Could not save search fixture \(prompt.title).")
        }

        try expect(store.matching("  cafe\nＢＥＴＡ  ").map(\.id) == [first.id, second.id],
                   "Search did not match all normalized terms in library order.")
        try expect(store.matching(" \n\t") == store.prompts, "A blank search did not show the library.")
    }

    private static func editsMultilineTextAndEmptyLibraryPersistWithShortcut() throws {
        let file = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PromptStore(fileURL: file)
        for prompt in store.prompts {
            try expect(store.remove(prompt.id), "Could not remove a starter prompt.")
        }
        var prompt = Prompt(title: "占位标题", body: "先保存", category: "开发", symbol: "terminal")
        let shortcut = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | controlKey), keyLabel: "P")
        try expect(store.upsert(prompt), "Could not create a prompt.")
        try expect(store.setShortcut(shortcut), "Could not save a shortcut.")

        prompt.title = "检查代码"
        prompt.body = "请检查以下代码。\n\n    return result\n"
        try expect(store.upsert(prompt), "Could not edit an existing prompt.")
        let reopened = PromptStore(fileURL: file)
        try expect(reopened.prompts == [prompt], "Reloading did not preserve the exact multiline prompt.")
        try expect(reopened.shortcut == shortcut && reopened.shortcut.display == shortcut.display,
                   "Reloading did not preserve the custom shortcut.")

        try expect(reopened.remove(prompt.id), "Could not remove the last prompt.")
        let empty = PromptStore(fileURL: file)
        try expect(empty.prompts.isEmpty, "Reloading an empty library restored the starters.")
        try expect(empty.shortcut == shortcut, "Removing the last prompt reset the custom shortcut.")
    }

    private static func failedSaveDoesNotReplaceCurrentLibrary() throws {
        let file = temporaryLibrary()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PromptStore(fileURL: file)
        let original = store.prompts
        try Data("目录位置被普通文件占用".utf8).write(to: folder)

        let prompt = Prompt(title: "新增", body: "提示词", category: "工作", symbol: "doc.text")
        try expect(!store.upsert(prompt), "Saving into an invalid destination succeeded.")
        try expect(store.prompts == original, "A failed save changed the in-memory library.")
        try expect(store.storageError != nil, "A failed save did not publish an error.")
    }

    private static func storesIndependentShortcutsAndRejectsDuplicates() throws {
        let file = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PromptStore(fileURL: file)
        try expect(store.shortcut == .defaultValue && store.compactShortcut == .compactDefaultValue,
                   "A new store did not use independent shortcut defaults.")

        let compact = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | controlKey), keyLabel: "P")
        let command = HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | optionKey), keyLabel: "F")
        try expect(store.setCompactShortcut(compact), "Could not save compact shortcut.")
        try expect(store.setShortcut(command), "Could not change command shortcut independently.")
        try expect(store.upsert(Prompt(title: "新增", body: "正文")), "Could not save a prompt with both bindings.")
        let beforeConflict = try Data(contentsOf: file)
        try expect(!store.setCompactShortcut(command) && !store.setShortcut(compact), "Store accepted duplicate shortcuts.")
        try expect(try Data(contentsOf: file) == beforeConflict, "Rejecting a shortcut collision modified the library.")

        let reopened = PromptStore(fileURL: file)
        try expect(reopened.shortcut == command && reopened.compactShortcut == compact,
                   "The two persisted bindings were lost or overwritten.")
    }

    private static func migratesLegacyShortcutsWithoutChangingTheCommandChord() throws {
        struct LegacyLibrary: Encodable {
            let prompts: [Prompt]
            let shortcut: HotKey
        }

        let file = temporaryLibrary()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prompt = Prompt(title: "旧提示词", body: "旧正文")
        for command in [HotKey.defaultValue, .compactDefaultValue] {
            let original = try JSONEncoder().encode(LegacyLibrary(prompts: [prompt], shortcut: command))
            try original.write(to: file)
            let store = PromptStore(fileURL: file)
            try expect(store.shortcut == command && store.prompts == [prompt], "Migration changed the existing library.")
            try expect(store.compactShortcut != command, "Migration assigned a chord already used by the command panel.")
            if command != .compactDefaultValue {
                try expect(store.compactShortcut == .compactDefaultValue, "Migration missed the normal compact default.")
            }
            try expect(try Data(contentsOf: file) == original, "Opening a legacy library rewrote its contents.")
            try expect(store.upsert(prompt), "Could not save a migrated library.")
            let reopened = PromptStore(fileURL: file)
            try expect(reopened.compactShortcut == store.compactShortcut, "The migrated binding did not persist.")
        }
    }

    private static func movingPromptsUpdatesStoredAndFilteredOrder() throws {
        let file = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = PromptStore(fileURL: file)
        let starters = store.prompts
        try expect(starters.count >= 2, "The starter library needs two entries for the no-op move check.")
        let missing = UUID()
        try expect(!store.movePrompt(missing, relativeTo: starters[0].id, after: true), "A missing source was accepted.")
        try expect(!store.movePrompt(starters[0].id, relativeTo: missing, after: false), "A missing target was accepted.")
        try expect(!store.movePrompt(starters[0].id, relativeTo: starters[0].id, after: false), "A self-drop was accepted.")
        try expect(store.movePrompt(starters[0].id, relativeTo: starters[1].id, after: false),
                   "An adjacent drop in the same position should succeed as a no-op.")
        try expect(store.movePrompt(starters[1].id, relativeTo: starters[0].id, after: true),
                   "An adjacent drop in the opposite direction should succeed as a no-op.")
        try expect(store.prompts == starters && !FileManager.default.fileExists(atPath: file.path),
                   "An invalid or no-op move wrote or changed the library.")

        let first = Prompt(title: "第一项", body: "待排序", category: "排序检查")
        let second = Prompt(title: "第二项", body: "待排序")
        let third = Prompt(title: "第三项", body: "待排序", category: "排序检查")
        for prompt in [first, second, third] {
            try expect(store.upsert(prompt), "Could not save reorder fixture \(prompt.title).")
        }

        try expect(store.movePrompt(first.id, relativeTo: third.id, after: true), "Could not move a prompt down.")
        try expect(store.prompts == starters + [second, third, first], "Moving down placed the prompt incorrectly.")
        try expect(store.movePrompt(third.id, relativeTo: second.id, after: false), "Could not move a prompt up.")
        try expect(store.prompts == starters + [third, second, first], "Moving up placed the prompt incorrectly.")

        let reopened = PromptStore(fileURL: file)
        try expect(reopened.prompts == store.prompts, "Reloading lost the changed prompt order.")
        try expect(reopened.matching("排序检查") == [third, first], "Filtering lost the changed prompt order.")
    }

    private static func unreadableLibraryIsPreservedWhenSaveIsAttempted() throws {
        let file = temporaryLibrary()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Data("This existing file is not valid JSON.".utf8)
        try original.write(to: file)

        let store = PromptStore(fileURL: file)
        let prompt = Prompt(title: "新增", body: "提示词", category: "工作", symbol: "doc.text")
        try expect(store.storageError != nil, "An unreadable library did not publish an error.")
        try expect(!store.upsert(prompt), "An unreadable library accepted a write.")
        try expect(try Data(contentsOf: file) == original, "An unreadable library was overwritten.")
    }

    private static func temporaryLibrary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptDockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(errorDescription: message) }
    }

    private struct CheckFailure: LocalizedError {
        let errorDescription: String?
    }
}

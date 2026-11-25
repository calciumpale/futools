import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CopilotMaterial: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case text, link, image, video

        var title: String {
            switch self {
            case .text: return "文案"
            case .link: return "链接"
            case .image: return "图片"
            case .video: return "视频"
            }
        }

        var symbol: String {
            switch self {
            case .text: return "text.alignleft"
            case .link: return "link"
            case .image: return "photo"
            case .video: return "film"
            }
        }

        var importType: UTType? {
            switch self {
            case .text, .link: return nil
            case .image: return .image
            case .video: return .movie
            }
        }
    }

    fileprivate struct Attachment: Codable, Equatable, Sendable {
        let id: UUID
        let fileName: String
    }

    let id: UUID
    var kind: Kind
    var title: String
    var body: String
    var isPinned: Bool
    var tags: [String]
    fileprivate var attachment: Attachment?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        body: String,
        isPinned: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.isPinned = isPinned
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, body, isPinned, tags, attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        attachment = try container.decodeIfPresent(Attachment.self, forKey: .attachment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        if isPinned { try container.encode(isPinned, forKey: .isPinned) }
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
        try container.encodeIfPresent(attachment, forKey: .attachment)
    }

    var linkHost: String? {
        guard kind == .link, let url = URL(string: body), let host = url.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

@MainActor
final class CopilotLibraryStore: ObservableObject {
    @Published private(set) var materials: [CopilotMaterial] = [] {
        didSet { rebuildSearchIndex() }
    }
    @Published private(set) var storageError: String?

    private let directory: URL
    private let catalog: URL
    private let assets: URL
    private var catalogReadable = true
    private var searchLocale = Locale.current
    private var searchIndex: [SearchEntry] = []

    private struct SearchEntry {
        let title: String
        let detail: SearchField?
    }

    private struct SearchField {
        let bytes: Data
        let compoundText: String?

        init(_ normalized: String) {
            bytes = Data(normalized.utf8)
            compoundText = normalized.unicodeScalars.count == normalized.count ? nil : normalized
        }

        var storedBytes: Int { bytes.count + (compoundText?.utf8.count ?? 0) }

        func contains(_ text: String, bytes needle: Data) -> Bool {
            bytes.range(of: needle) != nil && (compoundText?.contains(text) ?? true)
        }
    }

    init(directory: URL? = nil) {
        let directory = directory ?? URL.applicationSupportDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("Prompt Dock", isDirectory: true)
            .appendingPathComponent("Copilot", isDirectory: true)
        self.directory = directory.standardizedFileURL
        catalog = self.directory.appendingPathComponent("materials.json")
        assets = self.directory.appendingPathComponent("Assets", isDirectory: true)
        do {
            guard try Self.fileType(at: self.directory.deletingLastPathComponent()) == .typeDirectory,
                  try Self.fileType(at: self.directory) == .typeDirectory,
                  try Self.fileType(at: catalog) == .typeRegular else { throw Failure.storage }
            let items = try JSONDecoder().decode([CopilotMaterial].self, from: Data(contentsOf: catalog))
            let assetIDs = items.compactMap { $0.attachment?.id }
            guard Set(items.map(\.id)).count == items.count, Set(assetIDs).count == assetIDs.count,
                  items.allSatisfy(Self.validSavedItem) else { throw Failure.storage }
            materials = items
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // A missing catalog is an empty library.
        } catch {
            catalogReadable = false
            storageError = "无法读取素材库。原文件已保留。"
        }
        rebuildSearchIndex()
    }

    func count(of kind: CopilotMaterial.Kind) -> Int {
        materials.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    /// Matches a title inside a natural-language query, or all query words across a material's fields.
    /// Pinned items and title matches come first. Equal matches keep the library order.
    /// A blank query returns pinned materials followed by recent materials. Results never exceed `limit`.
    func search(_ query: String, kind: CopilotMaterial.Kind? = nil, limit: Int = 20) -> [CopilotMaterial] {
        guard limit > 0 else { return [] }
        if searchLocale != Locale.current { rebuildSearchIndex() }
        let normalized = Self.searchable(query, locale: searchLocale)
        let terms = normalized.split(whereSeparator: \.isWhitespace).map { (text: String($0), bytes: Data($0.utf8)) }

        if terms.isEmpty {
            var pinned: [CopilotMaterial] = []
            var regular: [CopilotMaterial] = []
            for material in materials {
                if let kind, material.kind != kind { continue }
                if material.isPinned {
                    pinned.append(material)
                    if pinned.count == limit { return pinned }
                } else if regular.count < limit {
                    regular.append(material)
                }
            }
            return Array((pinned + regular).prefix(limit))
        }

        var pinnedTitle: [CopilotMaterial] = []
        var titleMatches: [CopilotMaterial] = []
        var pinnedOther: [CopilotMaterial] = []
        var otherMatches: [CopilotMaterial] = []

        for (material, entry) in zip(materials, searchIndex) {
            if let kind, material.kind != kind { continue }
            let matchesTitle = (entry.title.count >= 2 && normalized.contains(entry.title))
                || terms.allSatisfy { entry.title.contains($0.text) }
            if matchesTitle {
                if material.isPinned {
                    pinnedTitle.append(material)
                    if pinnedTitle.count == limit { return pinnedTitle }
                } else if titleMatches.count < limit {
                    titleMatches.append(material)
                }
            } else if pinnedOther.count + otherMatches.count < limit {
                let detail = entry.detail ?? SearchField(Self.searchable(Self.searchDetails(material), locale: searchLocale))
                if terms.allSatisfy({ entry.title.contains($0.text) || detail.contains($0.text, bytes: $0.bytes) }) {
                    if material.isPinned {
                        pinnedOther.append(material)
                    } else if otherMatches.count < limit {
                        otherMatches.append(material)
                    }
                }
            }
        }
        return Array((pinnedTitle + titleMatches + pinnedOther + otherMatches).prefix(limit))
    }

    private func rebuildSearchIndex() {
        let locale = Locale.current
        searchLocale = locale
        var remainingBytes = 4 * 1_024 * 1_024
        searchIndex = materials.map { material in
            let title = Self.searchable(material.title, locale: locale)
            // Very long or late entries remain searchable without keeping a second copy of their text.
            guard material.body.utf8.count <= min(32_768, remainingBytes) else { return SearchEntry(title: title, detail: nil) }
            let detail = SearchField(Self.searchable(Self.searchDetails(material), locale: locale))
            guard detail.storedBytes <= remainingBytes else { return SearchEntry(title: title, detail: nil) }
            remainingBytes -= detail.storedBytes
            return SearchEntry(title: title, detail: detail)
        }
    }

    private static func searchDetails(_ material: CopilotMaterial) -> String {
        let tagText = material.tags.joined(separator: " ")
        return material.body + " " + tagText + " " + material.kind.title + " " + material.kind.rawValue
    }

    func attachmentURL(for material: CopilotMaterial) -> URL? {
        guard let current = materials.first(where: { $0.id == material.id }), current.kind == material.kind,
              let attachment = current.attachment, current.kind.importType != nil else { return nil }
        return storedFile(for: attachment)
    }

    func togglePin(_ id: UUID) throws {
        guard let index = materials.firstIndex(where: { $0.id == id }) else { return }
        var next = materials
        next[index].isPinned.toggle()
        try persist(next)
    }

    func save(_ material: CopilotMaterial, importing source: URL? = nil) async throws {
        guard catalogReadable else { throw Failure.storage }
        var updated = material
        updated.title = material.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tags = Self.normalizedTags(material.tags)
        guard !updated.title.isEmpty else { throw Failure.emptyTitle }
        let original = materials.first { $0.id == material.id }
        var imported: CopilotMaterial.Attachment?
        defer {
            if let imported { discard(imported) }
        }

        if let source {
            guard let type = updated.kind.importType else { throw Failure.invalidFile }
            do {
                try prepareLibraryDirectory()
                try prepareDirectory(assets)
            } catch { throw Failure.storage }
            let attachment = try await importFile(source, type: type)
            imported = attachment
            try Task.checkCancellation()
            guard materials.first(where: { $0.id == material.id }) == original else { throw Failure.changed }
            updated.attachment = attachment
            updated.body = attachment.fileName
        } else if updated.kind.importType != nil {
            guard original?.kind == updated.kind, let attachment = original?.attachment,
                  storedFile(for: attachment) != nil else { throw Failure.missingFile }
            updated.attachment = attachment
            updated.body = attachment.fileName
        } else {
            updated.attachment = nil
            let trimmedBody = updated.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if updated.kind == .link {
                guard Self.validLink(trimmedBody) else { throw Failure.invalidLink }
                updated.body = trimmedBody
            } else if trimmedBody.isEmpty {
                throw Failure.emptyBody
            }
        }

        var next = materials
        if let index = next.firstIndex(where: { $0.id == updated.id }) {
            next[index] = updated
        } else {
            next.insert(updated, at: 0)
        }
        try persist(next)
        imported = nil
        if let old = original?.attachment, old != updated.attachment { discard(old) }
    }

    func remove(_ id: UUID) throws {
        guard let material = materials.first(where: { $0.id == id }) else { return }
        try persist(materials.filter { $0.id != id })
        if let attachment = material.attachment { discard(attachment) }
    }

    static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let trimmed = String(entry.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
                if result.count == 6 { break }
            }
        }
        return result
    }

    static func parseTags(_ input: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；#")
        return normalizedTags(input.components(separatedBy: separators))
    }

    static func isValidWebLink(_ input: String) -> Bool {
        validLink(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func persist(_ items: [CopilotMaterial]) throws {
        guard catalogReadable else { throw Failure.storage }
        do {
            try prepareLibraryDirectory()
            if let type = try? Self.fileType(at: catalog), type != .typeRegular { throw Failure.storage }
            try JSONEncoder().encode(items).write(to: catalog, options: .atomic)
        } catch { throw Failure.storage }
        materials = items
        storageError = nil
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard try Self.fileType(at: url) == .typeDirectory else { throw Failure.storage }
    }

    private func prepareLibraryDirectory() throws {
        try prepareDirectory(directory.deletingLastPathComponent())
        try prepareDirectory(directory)
    }

    private func storedFile(for attachment: CopilotMaterial.Attachment) -> URL? {
        guard Self.safeFileName(attachment.fileName) else { return nil }
        let folder = assets.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(attachment.fileName)
        guard Self.isManagedAssetDirectory(assets),
              (try? Self.fileType(at: folder)) == .typeDirectory,
              (try? Self.fileType(at: url)) == .typeRegular else { return nil }
        return url
    }

    private func discard(_ attachment: CopilotMaterial.Attachment) {
        guard let url = storedFile(for: attachment) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            let folder = url.deletingLastPathComponent()
            if try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            storageError = "旧附件暂未能从本机清理。"
        }
    }

    private func importFile(_ source: URL, type: UTType) async throws -> CopilotMaterial.Attachment {
        let root = assets
        let task = Task.detached(priority: .userInitiated) {
            try await Self.copyFile(source, into: root, type: type)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func copyFile(_ source: URL, into root: URL, type: UTType) async throws -> CopilotMaterial.Attachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, (try? fileType(at: source)) == .typeRegular,
              let contentType = try? source.resourceValues(forKeys: [.contentTypeKey]).contentType,
              contentType.conforms(to: type) else { throw Failure.invalidFile }
        try Task.checkCancellation()
        let name = source.lastPathComponent
        let isImage = type == .image
        let fallbackName = (isImage ? "图片" : "视频") + "." + (contentType.preferredFilenameExtension ?? (isImage ? "png" : "mov"))
        let attachment = CopilotMaterial.Attachment(id: UUID(), fileName: safeFileName(name) ? name : fallbackName)
        let folder = root.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(attachment.fileName)
        let manager = FileManager.default
        do {
            guard isManagedAssetDirectory(root) else { throw Failure.storage }
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch { throw Failure.storage }

        do {
            try manager.copyItem(at: source, to: destination)
            guard try fileType(at: destination) == .typeRegular else { throw Failure.invalidFile }
            if isImage {
                guard let image = CGImageSourceCreateWithURL(destination as CFURL, nil),
                      CGImageSourceGetCount(image) > 0 else { throw Failure.invalidFile }
            } else {
                let video = AVURLAsset(url: destination)
                guard !(try await video.loadTracks(withMediaType: .video)).isEmpty else { throw Failure.invalidFile }
            }
            try Task.checkCancellation()
            return attachment
        } catch {
            if isManagedAssetDirectory(root), (try? fileType(at: folder)) == .typeDirectory {
                try? manager.removeItem(at: folder)
            }
            if Task.isCancelled { throw CancellationError() }
            throw Failure.invalidFile
        }
    }

    nonisolated private static func isManagedAssetDirectory(_ root: URL) -> Bool {
        let library = root.deletingLastPathComponent()
        return (try? fileType(at: library.deletingLastPathComponent())) == .typeDirectory &&
            (try? fileType(at: library)) == .typeDirectory && (try? fileType(at: root)) == .typeDirectory
    }

    nonisolated private static func safeFileName(_ name: String) -> Bool {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        return !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240 &&
            name.rangeOfCharacter(from: unsafe) == nil
    }

    nonisolated private static func fileType(at url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    private static func validLink(_ input: String) -> Bool {
        guard let parts = URLComponents(string: input), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty, parts.url != nil else { return false }
        return host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private static func validSavedItem(_ material: CopilotMaterial) -> Bool {
        guard !material.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch material.kind {
        case .text:
            return material.attachment == nil && !material.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .link:
            return material.attachment == nil && validLink(material.body)
        case .image, .video:
            guard let attachment = material.attachment else { return false }
            return safeFileName(attachment.fileName) && material.body == attachment.fileName
        }
    }

    private static func searchable(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .precomposedStringWithCanonicalMapping
    }

    enum Failure: LocalizedError {
        case emptyTitle, emptyBody, invalidLink, invalidFile, missingFile, changed, storage

        var errorDescription: String? {
            switch self {
            case .emptyTitle: return "请输入素材名称。"
            case .emptyBody: return "请输入文案内容。"
            case .invalidLink: return "请输入完整的 http 或 https 链接。"
            case .invalidFile: return "无法导入该文件，请选择可正常打开的图片或视频。"
            case .missingFile: return "请选择要导入的文件。"
            case .changed: return "素材在导入期间发生了变化，请重新打开后再试。"
            case .storage: return "无法保存素材库，请检查磁盘空间和目录权限。"
            }
        }
    }
}

@MainActor
final class CopilotThumbnailCache {
    static let shared = CopilotThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 80
    }

    func thumbnail(for url: URL, kind: CopilotMaterial.Kind, maxPixelSize: Int = 144) async -> NSImage? {
        let key = "\(url.path)::\(kind.rawValue)::\(maxPixelSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let cgImage: CGImage? = await Task.detached(priority: .utility) {
            switch kind {
            case .image:
                return Self.imageThumbnail(at: url, maxPixelSize: maxPixelSize)
            case .video:
                return await Self.videoThumbnail(at: url, maxPixelSize: maxPixelSize)
            case .text, .link:
                return nil
            }
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated private static func imageThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func videoThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try? await generator.image(at: .zero).image
    }
}

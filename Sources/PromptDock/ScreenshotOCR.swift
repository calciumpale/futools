import AppKit
import ImageIO
import UniformTypeIdentifiers

struct OCRImage: Sendable {
    private let bytes: Data
    private static let maximumBytes = 100 * 1_024 * 1_024
    private static let maximumPixels = 50_000_000
    private static let imageFormats: [UTType] = [.png, .jpeg, .tiff, .heic, .heif, .webP, .bmp, .gif]
    private static let imagePasteboardTypes = imageFormats.map { NSPasteboard.PasteboardType($0.identifier) }

    static var draggedPasteboardTypes: [NSPasteboard.PasteboardType] {
        imagePasteboardTypes + [.fileURL]
    }

    @MainActor
    static func canRead(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: imagePasteboardTypes) != nil { return true }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: imageFormats.map(\.identifier)
        ])
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard) throws -> OCRImage {
        let items = (pasteboard.pasteboardItems ?? []).filter { item in
            item.types.contains(.fileURL) || imagePasteboardTypes.contains(where: item.types.contains)
        }
        guard let item = items.first else { throw ScreenshotOCR.Failure.noImage }
        guard items.count == 1 else { throw ScreenshotOCR.Failure.multipleImages }

        if item.types.contains(.fileURL) {
            guard let location = item.string(forType: .fileURL), let url = URL(string: location) else {
                throw ScreenshotOCR.Failure.invalidImage
            }
            return try read(fileURL: url)
        }

        for type in imagePasteboardTypes where item.types.contains(type) {
            if let bytes = item.data(forType: type), !bytes.isEmpty {
                guard bytes.count <= maximumBytes else { throw ScreenshotOCR.Failure.imageTooLarge }
                return OCRImage(bytes: bytes)
            }
        }
        throw ScreenshotOCR.Failure.invalidImage
    }

    static func read(fileURL url: URL) throws -> OCRImage {
        guard url.isFileURL, !url.hasDirectoryPath, let format = UTType(filenameExtension: url.pathExtension),
              imageFormats.contains(where: format.conforms(to:)) else { throw ScreenshotOCR.Failure.invalidImage }
        let size = try validateFileSize(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ScreenshotOCR.Failure.invalidImage }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: size + 1), bytes.count == size else {
            throw ScreenshotOCR.Failure.invalidImage
        }
        return OCRImage(bytes: bytes)
    }

    @MainActor
    var preview: NSImage? {
        guard let thumbnail = try? thumbnail(maximumDimension: 480) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }

    fileprivate func uploadPNG() throws -> Data {
        let image = try thumbnail(maximumDimension: 6_144)
        let output = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotOCR.Failure.invalidImage
        }
        // Re-encode the oriented pixels only. Source names, locations and image metadata stay on the Mac.
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png) else { throw ScreenshotOCR.Failure.invalidImage }
        guard output.length <= Self.maximumBytes else { throw ScreenshotOCR.Failure.imageTooLarge }
        return output as Data
    }

    private func thumbnail(maximumDimension: Int) throws -> CGImage {
        let openOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, openOptions),
              let typeID = CGImageSourceGetType(imageSource), let type = UTType(typeID as String),
              Self.imageFormats.contains(where: type.conforms(to:)) else { throw ScreenshotOCR.Failure.invalidImage }
        let count = CGImageSourceGetCount(imageSource)
        if count > 1 { throw ScreenshotOCR.Failure.multipleImages }
        guard count == 1, let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, openOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
            throw ScreenshotOCR.Failure.invalidImage
        }
        guard width <= Self.maximumPixels / height else { throw ScreenshotOCR.Failure.imageTooLarge }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ScreenshotOCR.Failure.invalidImage
        }
        return image
    }

    private static func validateFileSize(_ url: URL) throws -> Int {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else {
            throw ScreenshotOCR.Failure.invalidImage
        }
        guard size <= maximumBytes else { throw ScreenshotOCR.Failure.imageTooLarge }
        return size
    }
}

enum ScreenshotOCR {
    static let endpoint = DeepSeekPromptAPI.baseURL.appending(path: "v1/tools/ocr")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 195
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    static func recognize(_ image: OCRImage) async throws -> String {
        try await recognize(image, loadKey: DeepSeekKeychain.load) { request in
            try await session.data(for: request)
        }
    }

    static func recognize(
        _ image: OCRImage,
        loadKey: () throws -> String?,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> String {
        try Task.checkCancellation()
        let key: String?
        do {
            key = try loadKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            try Task.checkCancellation()
            throw DeepSeekPromptAPI.Failure.keyUnavailable
        }
        guard let key, !key.isEmpty else { throw DeepSeekPromptAPI.Failure.missingKey }
        guard key.utf8.allSatisfy({ 33...126 ~= $0 }) else { throw DeepSeekPromptAPI.Failure.authenticationFailed }

        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try image.uploadPNG()
        }
        let png = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()

        let boundary = "PromptDockOCR-\(UUID().uuidString)"
        var body = Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\ntext_recognition\r\n" +
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"screenshot.png\"\r\n" +
            "Content-Type: image/png\r\n\r\n"
        ).utf8)
        body.append(png)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

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
            throw DeepSeekPromptAPI.Failure.timedOut
        } catch {
            try Task.checkCancellation()
            throw DeepSeekPromptAPI.Failure.networkUnavailable
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard http.url == endpoint else { throw DeepSeekPromptAPI.Failure.unexpectedRedirect }
        switch http.statusCode {
        case 200...299: break
        case 300...399: throw DeepSeekPromptAPI.Failure.unexpectedRedirect
        case 401, 403: throw DeepSeekPromptAPI.Failure.authenticationFailed
        case 402: throw DeepSeekPromptAPI.Failure.insufficientBalance
        case 408, 504: throw DeepSeekPromptAPI.Failure.timedOut
        case 413: throw Failure.imageTooLarge
        case 429: throw DeepSeekPromptAPI.Failure.rateLimited
        case 500...599: throw DeepSeekPromptAPI.Failure.serviceUnavailable
        default: throw Failure.requestRejected
        }

        guard data.count <= 1_024 * 1_024,
              let result = try? JSONDecoder().decode(ResponseBody.self, from: data) else { throw Failure.malformedResponse }
        // DeepSeek sends recognition failures in an HTTP 200 body after the upload succeeds.
        if let error = result.error {
            if error.code == "gateway_timeout_error" || error.type == "gateway_timeout_error" {
                throw DeepSeekPromptAPI.Failure.timedOut
            }
            if error.code == "invalid_request_error" || error.type == "invalid_request_error" {
                throw Failure.requestRejected
            }
            throw DeepSeekPromptAPI.Failure.serviceUnavailable
        }

        guard let pages = result.pages, result.pageCount == pages.count, !pages.isEmpty else { throw Failure.malformedResponse }
        let ordered = pages.sorted { $0.index < $1.index }
        for (index, page) in ordered.enumerated() {
            guard page.index == index else { throw Failure.malformedResponse }
            if page.finishReason == "length" { throw Failure.incompleteText }
            guard page.finishReason == "stop" else { throw Failure.malformedResponse }
        }
        let text = ordered.map { plainText($0.text) }.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    private static func plainText(_ input: String) -> String {
        // Keep recognized text and line breaks. Drop only the layout tags and their coordinates.
        input.replacingOccurrences(of: #"<[|｜](box|det)[|｜]>[\s\d.,+\-\[\]]*<[|｜]/\1[|｜]>"#,
                                   with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[|｜]/?(?:ref|box|det)[|｜]>"#, with: "", options: .regularExpression)
    }

    enum Failure: LocalizedError, Equatable {
        case noImage, multipleImages, invalidImage, imageTooLarge, requestRejected
        case malformedResponse, noText, incompleteText

        var errorDescription: String? {
            switch self {
            case .noImage: return "请粘贴或拖入一张截图。"
            case .multipleImages: return "一次只能识别一张图片，请单独选取截图。"
            case .invalidImage: return "无法读取这张图片，请重新截图或使用 PNG、JPEG 文件。"
            case .imageTooLarge: return "图片过大，请裁剪后再识别。"
            case .requestRejected: return "DeepSeek 无法识别这张图片，请重新截图后再试。"
            case .malformedResponse: return "DeepSeek 未返回可用的识别结果，请重试。"
            case .noText: return "未识别到文字，请换一张更清晰的截图。"
            case .incompleteText: return "识别结果不完整，请将截图裁剪成较小区域后重试。"
            }
        }
    }

    private struct ResponseBody: Decodable {
        struct Page: Decodable {
            let index: Int
            let text: String
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case index, text
                case finishReason = "finish_reason"
            }
        }

        struct ServiceError: Decodable {
            let code: String?
            let type: String?
        }

        let pages: [Page]?
        let pageCount: Int?
        let error: ServiceError?

        enum CodingKeys: String, CodingKey {
            case pages, error
            case pageCount = "page_count"
        }
    }

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

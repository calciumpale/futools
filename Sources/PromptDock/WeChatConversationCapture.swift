import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

enum WeChatConversationCapture {
    static func isRestricted(pid: pid_t, windowFrame: CGRect) -> Bool {
        guard pid > 0, valid(windowFrame),
              let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let matches = items.filter { item in
            item[kCGWindowLayer as String] as? Int == 0 && matchesWindow(item, pid: pid, frame: windowFrame)
        }
        guard matches.count == 1, let item = matches.first else { return false }
        return restrictsSharing(item)
    }

    static func indicatesRestriction(_ error: Error) -> Bool {
        (error as? Failure) == .captureRestricted
    }

    @MainActor
    static func recognize(pid: pid_t, windowFrame: CGRect, transcriptFrame: CGRect) async throws -> String {
        try Task.checkCancellation()
        guard pid > 0, valid(windowFrame), valid(transcriptFrame), windowFrame.contains(transcriptFrame),
              transcriptFrame != windowFrame else {
            throw Failure.invalidRegion
        }
        guard #available(macOS 14.2, *) else { throw Failure.unsupportedSystem }
        guard CGPreflightScreenCaptureAccess() else {
            // Prompt only after the explicit capture action. Retry with fresh geometry after authorizing.
            _ = CGRequestScreenCaptureAccess()
            throw Failure.permissionRequired
        }

        let cropped: CGImage
        do {
            cropped = try await capture(pid: pid, windowFrame: windowFrame, transcriptFrame: transcriptFrame)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw CGPreflightScreenCaptureAccess() ? Failure.captureFailed : Failure.permissionRequired
        }
        try Task.checkCancellation()
        return try await recognizeInBackground { cropped }
    }

    static func recognize(screenshot: OCRImage) async throws -> String {
        try await recognizeInBackground { try screenshot.localRecognitionImage() }
    }

    private static func recognizeInBackground(_ image: @escaping @Sendable () throws -> CGImage) async throws -> String {
        let recognition = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try recognizeText(in: image())
        }
        return try await withTaskCancellationHandler {
            let text = try await recognition.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            recognition.cancel()
        }
    }

    @available(macOS 14.2, *)
    @MainActor
    private static func capture(pid: pid_t, windowFrame: CGRect, transcriptFrame: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let matches = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == pid && ConversationApp(bundleIdentifier: owner.bundleIdentifier) != nil
                && window.isOnScreen && window.windowLayer == 0 && sameFrame(window.frame, windowFrame)
        }
        guard matches.count == 1, let window = matches.first else { throw Failure.windowUnavailable }
        guard window.frame.contains(transcriptFrame),
              content.displays.contains(where: { $0.frame.contains(transcriptFrame) }) else { throw Failure.invalidRegion }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard valid(filter.contentRect),
              abs(filter.contentRect.width - window.frame.width) <= 1,
              abs(filter.contentRect.height - window.frame.height) <= 1 else { throw Failure.windowUnavailable }
        let scale = min(CGFloat(filter.pointPixelScale), 4096 / max(window.frame.width, window.frame.height))
        guard scale.isFinite, scale > 0 else { throw Failure.captureFailed }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded(.up)))
        configuration.height = max(1, Int((window.frame.height * scale).rounded(.up)))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true

        try ensureCurrentWindow(window, pid: pid)
        // ScreenCaptureKit ignores sourceRect for an independent window. Crop before calling Vision.
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        try ensureCurrentWindow(window, pid: pid)
        return try crop(screenshot, windowFrame: window.frame, transcriptFrame: transcriptFrame)
    }

    private static func ensureCurrentWindow(_ window: SCWindow, pid: pid_t) throws {
        guard let items = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]],
              items.count == 1, let item = items.first,
              item[kCGWindowNumber as String] as? CGWindowID == window.windowID,
              matchesWindow(item, pid: pid, frame: window.frame) else {
            throw Failure.windowUnavailable
        }
        if restrictsSharing(item) { throw Failure.captureRestricted }
    }

    private static func matchesWindow(_ item: [String: Any], pid: pid_t, frame: CGRect) -> Bool {
        guard item[kCGWindowOwnerPID as String] as? pid_t == pid,
              item[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = item[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        return sameFrame(rect, frame)
    }

    private static func restrictsSharing(_ item: [String: Any]) -> Bool {
        (item[kCGWindowSharingState as String] as? UInt32) == CGWindowSharingType.none.rawValue
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
    }

    private static func sameFrame(_ first: CGRect, _ second: CGRect) -> Bool {
        valid(first) && valid(second) && abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
            && abs(first.maxX - second.maxX) <= 1 && abs(first.maxY - second.maxY) <= 1
    }

    private static func crop(_ image: CGImage, windowFrame: CGRect, transcriptFrame: CGRect) throws -> CGImage {
        guard windowFrame.contains(transcriptFrame) else { throw Failure.invalidRegion }
        let xScale = CGFloat(image.width) / windowFrame.width
        let yScale = CGFloat(image.height) / windowFrame.height
        // ScreenCaptureKit can return a window's native scale instead of the requested size.
        // Accept a common scale with up to one pixel of rounding per axis.
        guard abs(xScale - yScale) <= 1 / windowFrame.width + 1 / windowFrame.height else {
            throw Failure.captureFailed
        }
        let left = ceil((transcriptFrame.minX - windowFrame.minX) * xScale)
        let top = ceil((transcriptFrame.minY - windowFrame.minY) * yScale)
        let right = floor((transcriptFrame.maxX - windowFrame.minX) * xScale)
        let bottom = floor((transcriptFrame.maxY - windowFrame.minY) * yScale)
        // Rounding inward keeps neighboring interface pixels out of the OCR input.
        let pixelRegion = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard valid(pixelRegion), imageBounds.contains(pixelRegion), let cropped = image.cropping(to: pixelRegion) else {
            throw Failure.invalidRegion
        }
        return cropped
    }

    private static func recognizeText(in image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            throw Failure.recognitionFailed
        }
        try Task.checkCancellation()

        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.25 else { return nil }
            let text = candidate.string.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
            return Line(text: text, bounds: observation.boundingBox)
        }
        guard !lines.isEmpty else { throw Failure.noText }
        return recentText(lines)
    }

    private static func recentText(_ lines: [Line]) -> String {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let previous = rows.last?.first, abs(previous.bounds.midY - line.bounds.midY)
                < min(previous.bounds.height, line.bounds.height) * 0.45 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        let ordered = rows.flatMap { row in
            row.sorted { $0.bounds.minX < $1.bounds.minX }
        }
        var mostRecent: [String] = []
        var remaining = 3500
        for line in ordered.reversed() {
            let prefix = line.positionPrefix
            let available = remaining - prefix.count - (mostRecent.isEmpty ? 0 : 1)
            guard available > 0 else { break }
            if line.text.count > available {
                if mostRecent.isEmpty { mostRecent.append(prefix + String(line.text.suffix(available))) }
                break
            }
            mostRecent.append(prefix + line.text)
            remaining = available - line.text.count
        }
        return mostRecent.reversed().joined(separator: "\n")
    }

    private struct Line {
        let text: String
        let bounds: CGRect

        // Every line receives an outer marker. Text extracted from a bubble may start with a lookalike marker.
        var positionPrefix: String {
            "\(side?.rawValue ?? WeChatReplySpeakers.unlocatedScreenshotLine)："
        }

        private var side: WeChatReplySpeakers.ScreenshotSide? {
            let left = bounds.minX
            let right = 1 - bounds.maxX
            guard left.isFinite, right.isFinite, left >= 0, right >= 0, bounds.width > 0 else { return nil }
            if left < 0.24 && right - left > 0.20 { return .left }
            if right < 0.24 && left - right > 0.20 { return .right }
            return nil
        }
    }

    private enum Failure: LocalizedError, Equatable {
        case invalidRegion, unsupportedSystem, permissionRequired, windowUnavailable, captureRestricted
        case captureFailed, recognitionFailed, noText

        var errorDescription: String? {
            switch self {
            case .invalidRegion: return "无法确认聊天区域，请在屏幕内完整显示聊天窗口后重试。"
            case .unsupportedSystem: return "聊天窗口截图识别需要 macOS 14.2 或更新版本。"
            case .permissionRequired: return "请在系统设置的「隐私与安全性」中允许 futools 录制屏幕，再重新打开应用并重试。"
            case .windowUnavailable: return "无法确认当前聊天窗口，请保持窗口可见后重试。"
            case .captureRestricted: return "此会话限制截图，可粘贴聊天文字或截图。"
            case .captureFailed: return "无法截取当前聊天窗口，请重试。"
            case .recognitionFailed: return "本机文字识别失败，请重试。"
            case .noText: return "未识别出聊天文字，请框选消息气泡或粘贴清晰截图。"
            }
        }
    }
}

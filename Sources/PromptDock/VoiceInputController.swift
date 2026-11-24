import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class VoiceInputController: ObservableObject {
    enum Phase: Equatable {
        case idle, requestingPermission, recording, finishing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message: String?

    private var permissionTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var capture: Capture?

    func begin(onTranscript: @escaping (String) -> Void) {
        guard phase == .idle, permissionTask == nil else { return }
        message = nil
        if let problem = Self.permissionProblem() {
            message = problem
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            requestPermissions()
            return
        }

        let locale = Self.recognitionLocale(
            preferredLanguages: Locale.preferredLanguages + [Locale.current.identifier],
            supportedLocales: SFSpeechRecognizer.supportedLocales()
        )
        let recognizer = locale.flatMap { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            message = "系统语音识别暂时不可用，请检查系统语言和网络后重试。"
            return
        }

        let session = Capture(recognizer: recognizer, onTranscript: onTranscript)
        capture = session
        let id = session.id
        recognizer.queue = .main
        session.task = recognizer.recognitionTask(with: session.feed.request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failed = error != nil
            DispatchQueue.main.async { [weak self] in
                self?.receive(text, isFinal: isFinal, failed: failed, from: id)
            }
        }

        do {
            try session.startAudio()
            phase = .recording
        } catch {
            discardCapture()
            message = "无法启动麦克风，请检查录音设备和权限后重试。"
        }
    }

    func finish() {
        guard phase == .recording, let capture else { return }
        capture.stopAudio()
        if capture.hasEnded {
            deliver(capture, failed: false)
            return
        }

        phase = .finishing
        capture.task?.finish()
        let id = capture.id
        finishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2_400)) } catch { return }
            guard let self, let session = self.capture, session.id == id else { return }
            self.deliver(session, failed: false)
        }
    }

    func cancel() {
        permissionTask?.cancel()
        discardCapture()
        message = nil
    }

    private func requestPermissions() {
        phase = .requestingPermission
        permissionTask = Task { [weak self] in
            // This task only asks for permission. Recording always needs a separate press.
            if !Task.isCancelled, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if !Task.isCancelled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
                }
            }

            guard let self else { return }
            self.permissionTask = nil
            guard !Task.isCancelled else { return }
            self.phase = .idle
            if let problem = Self.permissionProblem() {
                self.message = problem
            } else if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      SFSpeechRecognizer.authorizationStatus() == .authorized {
                self.message = "授权完成，请再次长按说话。"
            } else {
                self.message = "尚未完成授权，请再次长按并按系统提示授权。"
            }
        }
    }

    private static func permissionProblem() -> String? {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone != .notDetermined && microphone != .authorized {
            return "请在系统设置的「隐私与安全性 → 麦克风」中允许 Prompt Dock。"
        }
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech != .notDetermined && speech != .authorized {
            return "请在系统设置的「隐私与安全性 → 语音识别」中允许 Prompt Dock。"
        }
        return nil
    }

    private func receive(_ text: String?, isFinal: Bool, failed: Bool, from id: UUID) {
        guard let capture, capture.id == id, !capture.hasEnded else { return }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            capture.transcript = text
        }
        guard isFinal || failed else { return }

        capture.hasEnded = true
        capture.stopAudio()
        if phase == .finishing || (failed && capture.transcript.isEmpty) {
            deliver(capture, failed: failed)
        } else {
            // A service can finalize early. Keep the text buffered until the user releases the button.
            message = "识别已结束，松开后填入文字。"
        }
    }

    private func deliver(_ capture: Capture, failed: Bool) {
        let text = capture.transcript
        discardCapture()
        if text.isEmpty {
            message = failed ? "语音识别未完成，请检查网络或换一段语音重试。"
                : "没有识别到语音，请再次长按并说话。"
        } else {
            message = nil
            capture.onTranscript(text)
        }
    }

    private func discardCapture() {
        finishTask?.cancel()
        finishTask = nil
        let abandoned = capture
        capture = nil
        abandoned?.cancel()
        phase = .idle
    }

    nonisolated static func recognitionLocale(preferredLanguages: [String], supportedLocales: Set<Locale>) -> Locale? {
        let supported = supportedLocales.sorted { $0.identifier < $1.identifier }

        func normalized(_ name: String) -> String {
            let identifier = name.split(separator: "@").first.map(String.init) ?? ""
            return identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        }

        for name in preferredLanguages where !name.isEmpty {
            let preferred = Locale(identifier: name)
            guard let language = preferred.language.languageCode?.identifier.lowercased() else { continue }
            let region = preferred.region?.identifier.uppercased()
            let script = preferred.language.script?.identifier.lowercased()
            var choices = [name]
            if language == "zh" {
                let traditional = script == "hant" || (script != "hans" && ["TW", "HK", "MO"].contains(region ?? ""))
                if traditional && (region == "HK" || region == "MO") {
                    choices.append(contentsOf: ["zh-HK", "yue-HK", "zh-TW"])
                } else if traditional {
                    choices.append(contentsOf: ["zh-TW", "zh-HK"])
                } else {
                    choices.append(contentsOf: region == "SG" ? ["zh-SG", "zh-CN"] : ["zh-CN", "zh-SG"])
                }
            } else if let region {
                choices.append("\(language)-\(region)")
            }

            for candidate in choices {
                if let match = supported.first(where: { normalized($0.identifier) == normalized(candidate) }) {
                    return match
                }
            }
            if let match = supported.first(where: { $0.language.languageCode?.identifier.lowercased() == language }) {
                return match
            }
        }
        return supported.first { normalized($0.identifier) == "en-us" }
    }

    private final class Capture {
        let id = UUID()
        let engine = AVAudioEngine()
        let feed = AudioFeed()
        let recognizer: SFSpeechRecognizer
        let onTranscript: (String) -> Void
        var task: SFSpeechRecognitionTask?
        var transcript = ""
        var hasEnded = false
        private var hasTap = false

        init(recognizer: SFSpeechRecognizer, onTranscript: @escaping (String) -> Void) {
            self.recognizer = recognizer
            self.onTranscript = onTranscript
            feed.request.shouldReportPartialResults = true
            feed.request.taskHint = .dictation
            feed.request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }

        deinit {
            cancel()
        }

        func startAudio() throws {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noInput }
            input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [feed] buffer, _ in
                feed.append(buffer)
            }
            hasTap = true
            engine.prepare()
            try engine.start()
        }

        func stopAudio() {
            if hasTap {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                hasTap = false
            }
            feed.end()
        }

        func cancel() {
            stopAudio()
            task?.cancel()
            task = nil
        }

        private enum CaptureError: Error { case noInput }
    }

    // The audio tap may complete a buffer while the UI ends the stream.
    private final class AudioFeed: @unchecked Sendable {
        let request = SFSpeechAudioBufferRecognitionRequest()
        private let lock = NSLock()
        private var ended = false

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                if !ended { request.append(buffer) }
            }
        }

        func end() {
            lock.withLock {
                guard !ended else { return }
                ended = true
                request.endAudio()
            }
        }
    }
}

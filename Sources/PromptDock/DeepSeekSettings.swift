import Foundation
import Security
import SwiftUI

enum DeepSeekKeychain {
    private static let credential = Credential(service: "local.promptdock.mac.deepseek-api")

    static func load() throws -> String? { try credential.load() }
    static func exists() throws -> Bool { try credential.exists() }
    static func save(_ key: String) throws { try credential.save(key) }
    static func remove() throws { try credential.remove() }

    struct Credential: Sendable {
        let service: String

        private var query: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "api-key"
            ]
        }

        func load() throws -> String? {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            try Self.check(status)
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                throw CredentialError.invalidData
            }
            return key
        }

        func exists() throws -> Bool {
            // Metadata is sufficient for the settings status. Only a requested optimization reads the key.
            var request = query
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return false }
            try Self.check(status)
            return true
        }

        func save(_ input: String) throws {
            let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.utf8.allSatisfy({ 33...126 ~= $0 }) else {
                throw CredentialError.invalidKey
            }

            let data = Data(key.utf8)
            let changes = [kSecValueData as String: data] as CFDictionary
            try Self.writes.withLock {
                let updated = SecItemUpdate(query as CFDictionary, changes)
                if updated != errSecItemNotFound {
                    try Self.check(updated)
                    return
                }

                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrLabel as String] = "futools · DeepSeek API Key"
                let added = SecItemAdd(attributes as CFDictionary, nil)
                if added == errSecDuplicateItem {
                    try Self.check(SecItemUpdate(query as CFDictionary, changes))
                } else {
                    try Self.check(added)
                }
            }
        }

        func remove() throws {
            try Self.writes.withLock {
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecItemNotFound { try Self.check(status) }
            }
        }

        private static let writes = NSLock()

        private static func check(_ status: OSStatus) throws {
            if status != errSecSuccess { throw CredentialError.keychain(status) }
        }
    }

    private enum CredentialError: LocalizedError {
        case invalidKey
        case invalidData
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "密钥格式有误，请直接粘贴 DeepSeek 提供的 API Key。"
            case .invalidData:
                return "无法读取钥匙串中的 DeepSeek 密钥，请重新保存。"
            case .keychain(errSecUserCanceled):
                return "已取消钥匙串操作。"
            case .keychain(errSecInteractionNotAllowed), .keychain(errSecAuthFailed), .keychain(errSecNotAvailable):
                return "无法访问 macOS 钥匙串。请确认登录钥匙串已解锁，再重试。"
            case .keychain:
                return "macOS 钥匙串操作失败，请重试。"
            }
        }
    }
}

// Select the property wrapper explicitly for builds using the standalone Command Line Tools.
private typealias CredentialState<Value> = SwiftUI.State<Value>

@MainActor
struct DeepSeekSettingsContent: View {
    let colors: DockColors

    @CredentialState private var input = ""
    @CredentialState private var hasKey: Bool?
    @CredentialState private var activity: Activity?
    @CredentialState private var feedback: Feedback?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBusy: Bool { activity != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("优化提示词会将草稿发送给 DeepSeek，截图 OCR 会发送截图，微信和飞书的回复建议会发送聊天文字及你填写的回复意图。聊天截图在本机识别。API Key 保存在 macOS 钥匙串。")
                .foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: "\(DeepSeekPromptAPI.modelID)  ·  \(DeepSeekPromptAPI.baseURL.absoluteString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 10)
                HStack(spacing: 5) {
                    DockActivityGlyph(isBusy: isBusy, idleSymbol: hasKey == true ? "checkmark.circle.fill" : "circle.dotted")
                    Text(statusText).contentTransition(.opacity)
                }
                .foregroundStyle(hasKey == true && !isBusy ? colors.accent : colors.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 89, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .animation(DockMotion.feedback(reduceMotion: reduceMotion), value: statusText)
            }
            HStack(spacing: 8) {
                SecureField(hasKey == true ? "输入新密钥" : "输入密钥", text: $input)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(colors.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line).allowsHitTesting(false) }
                    .accessibilityLabel("DeepSeek API Key")
                    .onSubmit(save)
                    .disabled(isBusy)
                Button(hasKey == true ? "替换密钥" : "保存密钥", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey == true {
                    Button("移除密钥", role: .destructive, action: remove)
                        .help("从本机钥匙串中移除")
                        .disabled(isBusy)
                }
            }

            VStack {
                if let feedback {
                    Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.circle" : "checkmark")
                        .foregroundStyle(feedback.isError ? colors.warning : colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .transition(DockMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .animation(DockMotion.transition(reduceMotion: reduceMotion), value: feedback?.message)
        }
        .onAppear { run(.checking) { try DeepSeekKeychain.exists() } }
        .onDisappear { input = "" }
    }

    private var statusText: String {
        if let activity { return activity.label }
        guard let hasKey else { return "状态未知" }
        return hasKey ? "已配置密钥" : "未配置密钥"
    }

    private func save() {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !key.isEmpty else { return }
        input = ""
        run(.saving, success: "已保存到钥匙串。") {
            try DeepSeekKeychain.save(key)
            return true
        }
    }

    private func remove() {
        guard hasKey == true else { return }
        input = ""
        run(.removing, success: "已移除本机密钥。") {
            try DeepSeekKeychain.remove()
            return false
        }
    }

    private func run(_ activity: Activity, success: String? = nil, operation: @escaping @Sendable () throws -> Bool) {
        guard !isBusy else { return }
        self.activity = activity
        feedback = nil
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated, operation: operation).result
            self.activity = nil
            switch result {
            case .success(let exists):
                hasKey = exists
                feedback = success.map { Feedback(message: $0, isError: false) }
            case .failure(let error):
                feedback = Feedback(message: error.localizedDescription, isError: true)
            }
        }
    }

    private enum Activity {
        case checking, saving, removing

        var label: String {
            switch self {
            case .checking: return "正在检查…"
            case .saving: return "正在保存…"
            case .removing: return "正在移除…"
            }
        }
    }

    private struct Feedback {
        let message: String
        let isError: Bool
    }
}

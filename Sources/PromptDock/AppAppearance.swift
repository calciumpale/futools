import AppKit

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let preferenceKey = "appAppearance"

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "日间"
        case .dark: return "夜间"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyStoredPreference() {
        let value = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        (Self(rawValue: value) ?? .system).apply()
    }
}

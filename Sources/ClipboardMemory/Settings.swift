import Foundation
import ServiceManagement
import Carbon.HIToolbox

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon modifier mask
    var display: String

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘V")
}

enum SensitiveAction: String, CaseIterable, Identifiable {
    case skip, store
    var id: String { rawValue }
    var title: String { self == .skip ? "Don’t save it" : "Save it anyway" }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var hotKey: HotKeyCombo { didSet { save(hotKey, "hotKey"); NotificationCenter.default.post(name: .hotKeyChanged, object: nil) } }
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: "retentionDays") } }
    @Published var maxEntries: Int { didSet { d.set(maxEntries, forKey: "maxEntries") } }
    @Published var maxImageMB: Int { didSet { d.set(maxImageMB, forKey: "maxImageMB") } }
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: "excludedApps") } }
    @Published var protectSensitive: Bool { didSet { d.set(protectSensitive, forKey: "protectSensitive") } }
    @Published var sensitiveAction: SensitiveAction { didSet { d.set(sensitiveAction.rawValue, forKey: "sensitiveAction") } }
    @Published var indexImageText: Bool { didSet { d.set(indexImageText, forKey: "indexImageText") } }
    @Published var paused: Bool { didSet { d.set(paused, forKey: "paused"); NotificationCenter.default.post(name: .pauseChanged, object: nil) } }
    @Published var launchAtLogin: Bool = false

    private init() {
        d.register(defaults: [
            "retentionDays": 90, "maxEntries": 10_000, "maxImageMB": 25,
            "protectSensitive": true, "sensitiveAction": SensitiveAction.skip.rawValue,
            "indexImageText": true, "paused": false,
            "excludedApps": ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords"],
        ])
        hotKey = (d.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) }) ?? .default
        retentionDays = d.integer(forKey: "retentionDays")
        maxEntries = d.integer(forKey: "maxEntries")
        maxImageMB = d.integer(forKey: "maxImageMB")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        protectSensitive = d.bool(forKey: "protectSensitive")
        sensitiveAction = SensitiveAction(rawValue: d.string(forKey: "sensitiveAction") ?? "") ?? .skip
        indexImageText = d.bool(forKey: "indexImageText")
        paused = d.bool(forKey: "paused")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return "Couldn’t change the login item. Make sure the app is in /Applications. (\(error.localizedDescription))"
        }
    }
}

extension Notification.Name {
    static let hotKeyChanged = Notification.Name("hotKeyChanged")
    static let pauseChanged = Notification.Name("pauseChanged")
    static let historyChanged = Notification.Name("historyChanged")
}

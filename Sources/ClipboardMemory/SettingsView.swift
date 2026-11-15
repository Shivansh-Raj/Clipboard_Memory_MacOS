import SwiftUI
import AppKit
import ClipboardCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let store: HistoryStore
    let onClear: () -> Void

    var body: some View {
        TabView {
            GeneralTab(settings: settings).tabItem { Label("General", systemImage: "gearshape") }
            HistoryTab(settings: settings, store: store, onClear: onClear).tabItem { Label("History", systemImage: "clock") }
            PrivacyTab(settings: settings).tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Open clipboard history")
                    Spacer()
                    ShortcutRecorder(combo: $settings.hotKey)
                }
                Text("Click the shortcut, then press the new key combination (it must include ⌘, ⌃ or ⌥).").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { loginError = settings.setLaunchAtLogin($0) }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Pause clipboard monitoring", isOn: $settings.paused)
            }
            Section("In the history window") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("↩ copy   ⌘↩ copy & close   ⌥↩ copy as plain text").font(.caption)
                    Text("⌘P pin   ⌘D favourite   ⌫ delete   ⌘F search   ⇥ next filter   ⌘1–8 pick filter   esc close").font(.caption)
                }.foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct HistoryTab: View {
    @ObservedObject var settings: AppSettings
    let store: HistoryStore
    let onClear: () -> Void
    @State private var count = 0

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: $settings.retentionDays) {
                    Text("1 week").tag(7); Text("1 month").tag(30); Text("3 months").tag(90)
                    Text("1 year").tag(365); Text("Forever").tag(0)
                }
                Picker("Keep at most", selection: $settings.maxEntries) {
                    Text("1,000 items").tag(1_000); Text("5,000 items").tag(5_000); Text("10,000 items").tag(10_000)
                    Text("50,000 items").tag(50_000); Text("Unlimited").tag(0)
                }
                Picker("Largest image to save", selection: $settings.maxImageMB) {
                    Text("5 MB").tag(5); Text("25 MB").tag(25); Text("100 MB").tag(100)
                }
                Text("Pinned items are never removed by automatic cleanup.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Saved items", value: count.formatted())
                LabeledContent("Location") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
                }
                Button("Clear History…", role: .destructive, action: onClear)
            }
        }
        .formStyle(.grouped)
        .onAppear { count = store.totalCount() }
    }
}

private struct PrivacyTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Sensitive content") {
                Toggle("Detect passwords, API keys and tokens", isOn: $settings.protectSensitive)
                Picker("When detected", selection: $settings.sensitiveAction) {
                    ForEach(SensitiveAction.allCases) { Text($0.title).tag($0) }
                }.disabled(!settings.protectSensitive)
                Text("Copies flagged as concealed by password managers are always ignored.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored apps") {
                if settings.excludedApps.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(settings.excludedApps, id: \.self) { id in
                    HStack {
                        Text(appName(id)); Spacer()
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Button { settings.excludedApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addApp() }
            }
            Section("Images") {
                Toggle("Index text inside copied images (on-device)", isOn: $settings.indexImageText)
            }
            Section("About privacy") {
                Text("History is stored only on this Mac, in ~/Library/Application Support/Clipboard Memory. The app has no network code, no telemetry, and never writes clipboard contents to logs. It needs no Accessibility, Screen Recording or Input Monitoring permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        if !settings.excludedApps.contains(id) { settings.excludedApps.append(id) }
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Press shortcut…" : combo.display)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else { NSSound.beep(); return nil }
            combo = HotKeyCombo(keyCode: UInt32(e.keyCode), modifiers: HotKeyFormat.carbonModifiers(mods), display: HotKeyFormat.display(for: e))
            stop(); return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

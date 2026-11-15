import AppKit
import SwiftUI
import ClipboardCore

/// Shared handles for views and controllers.
final class AppContext {
    static var shared: AppContext?
    let store: HistoryStore
    let writer: PasteboardWriter
    let vm: HistoryViewModel
    var showSettings: () -> Void = {}
    init(store: HistoryStore) {
        self.store = store
        writer = PasteboardWriter(store: store)
        vm = HistoryViewModel(store: store, writer: writer)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var context: AppContext!
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private var hotKey: HotKeyManager!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var pauseItem: NSMenuItem!
    private var openItem: NSMenuItem!
    private let settings = AppSettings.shared
    private var purgeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only: if already running, bring up its history and quit.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != NSRunningApplication.current }) {
            DistributedNotificationCenter.default().postNotificationName(.init("ClipboardMemory.show"), object: nil)
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipboard Memory", isDirectory: true)
        let store: HistoryStore
        do { store = try HistoryStore(directory: support) } catch {
            let a = NSAlert(); a.messageText = "Clipboard Memory can’t open its history"
            a.informativeText = "The history database at \(support.path) couldn’t be opened or created. Check the folder’s permissions and relaunch."
            a.runModal(); NSApp.terminate(nil); return
        }
        context = AppContext(store: store)
        AppContext.shared = context
        context.showSettings = { [weak self] in self?.showSettings() }

        monitor = ClipboardMonitor(store: store, writer: context.writer)
        monitor.start()
        panel = PanelController(vm: context.vm)

        hotKey = HotKeyManager { [weak self] in self?.panel.toggle() }
        registerHotKey(announceFailure: true)
        NotificationCenter.default.addObserver(forName: .hotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey(announceFailure: true); self?.refreshMenu()
        }
        NotificationCenter.default.addObserver(forName: .pauseChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshMenu() }
        DistributedNotificationCenter.default().addObserver(forName: .init("ClipboardMemory.show"), object: nil, queue: .main) { [weak self] _ in self?.panel.show() }

        buildMainMenu()
        buildStatusItem()

        runRetention()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.runRetention() }
        purgeTimer?.tolerance = 300

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWelcome() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show(); return false
    }

    private func runRetention() {
        let s = settings
        DispatchQueue.global(qos: .utility).async { [store = context.store] in
            store.purge(olderThanDays: s.retentionDays, maxEntries: s.maxEntries)
        }
    }

    private func registerHotKey(announceFailure: Bool) {
        if !hotKey.register(settings.hotKey), announceFailure {
            let a = NSAlert()
            a.messageText = "Couldn’t register the shortcut \(settings.hotKey.display)"
            a.informativeText = "Another app may already be using it. Choose a different shortcut in Settings."
            a.runModal()
        }
    }

    // MARK: Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clipboard Memory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.delegate = self
        openItem = menu.addItem(withTitle: "Open Clipboard History", action: #selector(openHistory), keyEquivalent: ""); openItem.target = self
        menu.addItem(.separator())
        pauseItem = menu.addItem(withTitle: "Pause Monitoring", action: #selector(togglePause), keyEquivalent: ""); pauseItem.target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipboard Memory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        openItem?.title = "Open Clipboard History   \(settings.hotKey.display)"
        pauseItem?.title = settings.paused ? "Resume Monitoring" : "Pause Monitoring"
        let name = settings.paused ? "pause.circle" : "doc.on.clipboard"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Clipboard Memory")
        img?.isTemplate = true
        statusItem?.button?.image = img
        statusItem?.button?.toolTip = settings.paused ? "Clipboard Memory – paused" : "Clipboard Memory"
    }

    @objc private func openHistory() { panel.show() }
    @objc private func togglePause() { settings.paused.toggle() }

    @objc private func clearHistory() {
        let a = NSAlert()
        a.messageText = "Clear clipboard history?"
        a.informativeText = "This permanently deletes saved clipboard entries from this Mac. It can’t be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Clear, Keep Pinned & Favourites")
        a.addButton(withTitle: "Clear Everything")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: context.store.clear(keepPinned: true, keepFavorites: true)
        case .alertSecondButtonReturn: context.store.clear(keepPinned: false)
        default: return
        }
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }

    @objc private func openSettings() { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Clipboard Memory Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings, store: context.store, onClear: { [weak self] in self?.clearHistory() }))
            w.center()
            settingsWindow = w
        }
        panel.hide()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showWelcome() {
        let a = NSAlert()
        a.messageText = "Clipboard Memory is running"
        a.informativeText = """
        Copy as usual. Press \(settings.hotKey.display) anywhere to search your clipboard history, then press Return to copy an item back and ⌘V to paste.

        • Everything stays on this Mac. Nothing is sent anywhere.
        • No special macOS permissions are needed. If macOS asks whether this app may “paste from other apps”, choose Allow so it can see what you copy.
        • Look for the clipboard icon in your menu bar to pause, open Settings or quit.
        """
        a.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

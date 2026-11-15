import AppKit
import SwiftUI
import Carbon.HIToolbox
import ClipboardCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    private let vm: HistoryViewModel
    private var monitor: Any?
    private var modalDepth = 0

    init(vm: HistoryViewModel) {
        self.vm = vm
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                              styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 600, height: 380)
        panel.delegate = self
        panel.setFrameAutosaveName("ClipboardMemoryPanel")

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        let host = NSHostingView(rootView: HistoryView(vm: vm))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        vm.onClose = { [weak self] in self?.hide() }
        vm.beginModal = { [weak self] in self?.modalDepth += 1 }
        vm.endModal = { [weak self] in self?.modalDepth -= 1; self?.panel.makeKeyAndOrderFront(nil) }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { (panel.isVisible && panel.isKeyWindow) ? hide() : show() }

    func show() {
        vm.prepareForShow()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        var size = panel.frame.size
        size.width = min(size.width, v.width - 40); size.height = min(size.height, v.height - 40)
        let origin = NSPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - v.height * 0.16)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        installMonitor()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        vm.focusSearchToken += 1
    }

    func hide() {
        removeMonitor()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.modalDepth == 0, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            if NSApp.keyWindow != nil && NSApp.keyWindow !== self.panel && NSApp.keyWindow?.isSheet == true { return }
            self.hide()
        }
    }

    // MARK: Keyboard

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let cmd = flags == .command
        let code = Int(e.keyCode)
        let editing = vm.editingTags
        let searchEmpty = vm.search.isEmpty

        // Standard editing shortcuts (an accessory app has no active menu bar, so route them ourselves).
        if cmd, let chars = e.charactersIgnoringModifiers, panel.firstResponder is NSText {
            let sel: Selector? = ["a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
                                  "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:))][chars]
            if let sel { return NSApp.sendAction(sel, to: nil, from: nil) }
            if chars == "z" { panel.firstResponder?.undoManager?.undo(); return true }
        }
        if flags == [.command, .shift], e.charactersIgnoringModifiers == "z" { panel.firstResponder?.undoManager?.redo(); return true }

        switch code {
        case kVK_Escape:
            if editing { vm.editingTags = false; vm.focusSearchToken += 1; return true }
            hide(); return true
        case kVK_ANSI_F where cmd:
            vm.focusSearchToken += 1; return true
        case kVK_ANSI_P where cmd:
            vm.togglePin(); return true
        case kVK_ANSI_D where cmd:
            vm.toggleFavorite(); return true
        case kVK_ANSI_W where cmd:
            hide(); return true
        case kVK_ANSI_Comma where cmd:
            AppContext.shared?.showSettings(); return true
        case kVK_UpArrow where !editing && flags.isEmpty:
            vm.move(-1); return true
        case kVK_DownArrow where !editing && flags.isEmpty:
            vm.move(1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if editing { return false }
            if flags == .command { vm.copySelected(close: true); return true }
            if flags == .option { vm.copySelected(plain: true); return true }
            if flags.isEmpty { vm.copySelected(); return true }
            return false
        case kVK_Delete, kVK_ForwardDelete:
            if editing { return false }
            if cmd || (flags.isEmpty && searchEmpty) { vm.deleteSelected(); return true }
            return false
        case kVK_Tab where !editing:
            vm.cycleFilter(flags.contains(.shift) ? -1 : 1); return true
        default:
            if cmd, !editing, let idx = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8].firstIndex(of: code) {
                vm.filter = HistoryFilter.allCases[idx]; return true
            }
            return false
        }
    }
}

import AppKit
import SwiftUI

@main struct QuickChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: ChatPanel!
    private var store: ChatStore!
    private var auth: AuthService!
    private var hotkey: GlobalShortcut!
    private let state = WindowState()
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A single process owns rotating credentials and local history.
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo")
        store = ChatStore(demo: demo); auth = AuthService(preview: demo); hotkey = GlobalShortcut()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "QuickChat")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "QuickChat"; panel.identifier = NSUserInterfaceItemIdentifier("QuickChatPanel")
        panel.minSize = NSSize(width: 600, height: 420); panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: RootView(store: store, auth: auth, window: state, hotkey: hotkey))
        state.dismiss = { [weak self] in self?.hide() }
        state.toggleHistory = { [weak self] in self?.toggleHistory() }
        hotkey.action = { [weak self] in self?.toggle() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, !self.state.settingsVisible,
                  !(self.panel.firstResponder is RecorderButton) else { return event }
            if event.keyCode == 53 { self.hide(); return nil }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers {
                case "n": self.store.newChat(); return nil
                case "b": self.toggleHistory(); return nil
                case ",": self.state.settingsVisible = true; return nil
                case "w": self.hide(); return nil
                case "q": NSApp.terminate(nil); return nil
                default: break
                }
            }
            return event
        }
        let menu = NSMenu()
        let appMenu = NSMenuItem(); appMenu.submenu = NSMenu(title: "QuickChat")
        appMenu.submenu?.addItem(withTitle: "Quit QuickChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appMenu)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(edit); NSApp.mainMenu = menu
        show()
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open QuickChat", action: #selector(openFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit QuickChat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { toggle() }
    }
    @objc private func openFromMenu() { show() }
    @objc private func settingsFromMenu() { show(); state.settingsVisible = true }
    private func toggle() { if panel.isKeyWindow { hide() } else { show() } }
    private func show() {
        let active = NSWorkspace.shared.frontmostApplication
        if active?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = active }
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 45))
            }
        }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        store.focusRequest = UUID()
    }
    private func hide() {
        panel.orderOut(nil)
        previousApp?.activate(options: [])
        Task { await store.flush() }
    }
    private func toggleHistory() {
        state.historyVisible.toggle()
        var frame = panel.frame
        frame.size.width += state.historyVisible ? 223 : -223
        frame.size.width = max(state.historyVisible ? 823 : 600, frame.size.width)
        if let screen = panel.screen?.visibleFrame { frame.origin.x = min(frame.origin.x, screen.maxX - frame.width) }
        panel.minSize = NSSize(width: state.historyVisible ? 823 : 600, height: 420)
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil, !terminating else { return .terminateNow }
        terminating = true; auth.cancelSignIn(); store.stop()
        Task { await store.flush(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if panel != nil { show() }; return true }
}

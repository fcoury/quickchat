import AppKit
import SwiftUI

@main enum QuickChatApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // AppKit owns the single panel; a SwiftUI Settings scene creates a second window.
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var panel: ChatPanel!
    private var store: ChatStore!
    private var auth: AuthService!
    private var hotkey: GlobalShortcut!
    private let state = WindowState()
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var terminating = false
    private var positionedPanel = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A single process owns rotating credentials and local history.
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo")
        store = ChatStore(demo: demo); auth = AuthService(preview: demo); hotkey = GlobalShortcut(preview: demo)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Clicking the panel must activate QuickChat so edit shortcuts reach its composer.
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "QuickChat"; panel.identifier = NSUserInterfaceItemIdentifier("QuickChatPanel")
        panel.minSize = NSSize(width: 600, height: 420); panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.isRestorable = false
        panel.level = state.keepOnTop ? .floating : .normal
        state.updateWindowLevel = { [weak self] keepOnTop in self?.panel.level = keepOnTop ? .floating : .normal }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: RootView(store: store, auth: auth, window: state, hotkey: hotkey))
        if !demo {
            positionedPanel = panel.setFrameUsingName("QuickChatPanel")
            panel.setFrameAutosaveName("QuickChatPanel")
        }
        state.dismiss = { [weak self] in self?.hide() }
        state.toggleHistory = { [weak self] in self?.toggleHistory() }
        hotkey.action = { [weak self] in self?.toggle() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if let recorder = self.panel.firstResponder as? RecorderButton, recorder.recording { return event }
            if self.state.handleFontSizeShortcut(event) { return nil }
            if self.state.handleHistoryShortcut(event) { return nil }
            if self.state.handleLatestShortcut(event) { return nil }
            if event.keyCode == 53 {
                if self.state.settingsVisible { self.state.settingsVisible = false; self.store.focusRequest = UUID() }
                else { self.hide() }
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers {
                case "n": self.state.settingsVisible = false; self.store.newChat(); return nil
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
        menu.addItem(edit)
        let view = NSMenuItem(); view.submenu = NSMenu(title: "View")
        view.submenu?.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleHistory), keyEquivalent: "b").target = self
        view.submenu?.addItem(withTitle: "Jump to Latest", action: #selector(jumpToLatest), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)).target = self
        menu.addItem(view); NSApp.mainMenu = menu
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
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let ring = NSBezierPath(ovalIn: NSRect(x: 1, y: 3, width: 14, height: 14))
            ring.appendOval(in: NSRect(x: 4.5, y: 6.5, width: 7, height: 7))
            ring.windingRule = .evenOdd
            ring.fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 10, y: 5))
            tail.line(to: NSPoint(x: 15.2, y: 1.5))
            tail.curve(to: NSPoint(x: 16, y: 2.3), controlPoint1: NSPoint(x: 16, y: 1), controlPoint2: NSPoint(x: 16.5, y: 1.5))
            tail.line(to: NSPoint(x: 13.5, y: 7))
            tail.close(); tail.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QuickChat"
        return image
    }
    private func toggle() { if panel.isKeyWindow { hide() } else { show() } }
    private func show() {
        let active = NSWorkspace.shared.frontmostApplication
        if active?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = active }
        // Keep a dragged/resized panel in place; recenter only initially or if its display disappeared.
        if !positionedPanel || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 45))
                positionedPanel = true
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        store.focusRequest = UUID()
    }
    private func hide() {
        panel.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        previousApp?.activate(options: [])
        Task { await store.flush() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
    @objc private func toggleHistory() {
        state.historyVisible.toggle()
        if !state.historyVisible { store.focusRequest = UUID() }
    }
    @objc private func jumpToLatest() { state.scrollToBottomRequest = UUID() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleHistory) || item.action == #selector(jumpToLatest) else { return true }
        return panel?.isKeyWindow == true && !state.settingsVisible &&
            !((panel.firstResponder as? RecorderButton)?.recording ?? false)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil, !terminating else { return .terminateNow }
        terminating = true; auth.cancelSignIn(); store.stop()
        Task { await store.flush(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if panel != nil { show() }; return false }
}

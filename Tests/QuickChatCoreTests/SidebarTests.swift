import AppKit
import QuickChatCore
import SwiftUI
import XCTest
@testable import QuickChat

final class SidebarTests: XCTestCase {
    @MainActor func testShortcutModifiersAndSettingsExclusion() throws {
        let suite = "QuickChat-SidebarTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WindowState(defaults: defaults)
        state.toggleHistory = { [weak state] in state?.historyVisible.toggle() }
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 11))
        }
        XCTAssertTrue(state.handleHistoryShortcut(try key("b")))
        XCTAssertTrue(state.historyVisible)
        XCTAssertTrue(state.handleHistoryShortcut(try key("B", [.command, .capsLock])))
        XCTAssertFalse(state.historyVisible)
        XCTAssertTrue(state.handleHistoryShortcut(try key("b", [.command, .numericPad])))
        for modifiers: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(state.handleHistoryShortcut(try key("b", modifiers)))
        }
        XCTAssertFalse(state.handleHistoryShortcut(try key("n")))
        state.settingsVisible = true
        XCTAssertFalse(state.handleHistoryShortcut(try key("b")))
        XCTAssertTrue(state.historyVisible)
    }

    @MainActor func testNativeSidebarFitsWithoutMovingOrResizingPanel() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-SidebarTests-\(UUID())")
        let suite = "QuickChat-SidebarTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ChatStore(demo: true, history: HistoryStore(root: root))
        await store.load()
        let draft = store.current?.draft
        let state = WindowState(defaults: defaults)
        let auth = AuthService(preview: true)
        let hotkey = GlobalShortcut(preview: true)
        for width: CGFloat in [600, 680, 1200] {
            state.historyVisible = false
            let frame = NSRect(x: 100, y: 100, width: width, height: 520)
            let panel = ChatPanel(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            panel.minSize = NSSize(width: 600, height: 420)
            let host = NSHostingView(rootView: RootView(store: store, auth: auth, window: state, hotkey: hotkey))
            panel.contentView = host
            for visible in [false, true, false] {
                state.historyVisible = visible
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(panel.frame, frame, "Sidebar must reflow inside the panel, including at minimum width.")
                XCTAssertEqual(host.bounds.width, width, accuracy: 1)
                XCTAssertEqual(store.current?.draft, draft)
                if let directory = ProcessInfo.processInfo.environment["QUICKCHAT_SIDEBAR_EVIDENCE_DIR"] {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try data.write(to: output.appendingPathComponent("sidebar-\(Int(width))-\(visible ? "open" : "closed").png"))
                }
            }
            panel.contentView = nil
        }
    }

    @MainActor func testLatestShortcutLeavesReturnEscapeAndModifiedArrowsAlone() throws {
        let suite = "QuickChat-LatestTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WindowState(defaults: defaults)
        func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
        }
        let initial = state.scrollToBottomRequest
        XCTAssertTrue(state.handleLatestShortcut(try key(125, [.command, .numericPad, .function])))
        XCTAssertNotEqual(state.scrollToBottomRequest, initial)
        let requested = state.scrollToBottomRequest
        for code: UInt16 in [36, 53, 126] { XCTAssertFalse(state.handleLatestShortcut(try key(code))) }
        for modifiers: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(state.handleLatestShortcut(try key(125, modifiers)))
        }
        state.settingsVisible = true
        XCTAssertFalse(state.handleLatestShortcut(try key(125)))
        XCTAssertEqual(state.scrollToBottomRequest, requested)
    }

    @MainActor func testJumpReachesActualBottomOfLongTranscript() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-ScrollTests-\(UUID())")
        let suite = "QuickChat-ScrollTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ChatStore(demo: true, history: HistoryStore(root: root))
        await store.load()
        store.chats[0].messages = (0..<20).map { index in
            Message(role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "Message \(index)\n\n" + String(repeating: "A paragraph with enough text to wrap across several lines. ", count: 5 + index % 5))
        }
        let state = WindowState(defaults: defaults)
        let panel = ChatPanel(contentRect: NSRect(x: 100, y: 100, width: 680, height: 520),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TranscriptView(store: store, auth: AuthService(preview: true), window: state, fontSize: 15))
        panel.contentView = host
        defer { panel.contentView = nil }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        try await settle()
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertGreaterThan(document.bounds.maxY - scroll.documentVisibleRect.maxY, 1000)
        state.scrollToBottomRequest = UUID()
        try await settle()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 2,
            "One jump must reach the real bottom even when lazy message heights change during scrolling.")
        store.chats[0].messages[19].text += String(repeating: " More streamed text.", count: 40)
        try await settle()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 2,
            "A growing answer should stay pinned after jumping to latest.")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        store.chats[0].messages[19].text += " One more update."
        try await settle()
        XCTAssertGreaterThan(document.bounds.maxY - scroll.documentVisibleRect.maxY, 1000,
            "Streaming must not pull the reader down after they scroll up.")
    }
}

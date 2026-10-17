import AppKit
import QuickChatCore
import SwiftUI
import XCTest
@testable import QuickChat

final class WindowDragTests: XCTestCase {
    @MainActor func testHeaderDragTargetReceivesMouseAndStartsNativeDrag() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-DragTests-\(UUID())")
        let suite = "QuickChat-DragTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ChatStore(demo: true, history: HistoryStore(root: root))
        await store.load()
        let state = WindowState(defaults: defaults)
        let panel = DragRecordingPanel(contentRect: NSRect(x: 100, y: 100, width: 600, height: 420),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RootView(store: store, auth: AuthService(preview: true),
            window: state, hotkey: GlobalShortcut(preview: true)))
        panel.contentView = host
        defer { panel.contentView = nil }
        func dragViews(in view: NSView) -> [WindowDragView] {
            (view as? WindowDragView).map { [$0] } ?? view.subviews.flatMap { dragViews(in: $0) }
        }
        for (history, settings) in [(false, false), (true, false), (true, true)] {
            state.historyVisible = history
            state.settingsVisible = settings
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let target = try XCTUnwrap(dragViews(in: host).first)
            XCTAssertGreaterThanOrEqual(target.bounds.width, 24)
            XCTAssertGreaterThan(target.bounds.height, 20)
            let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: host.superview)
            XCTAssertTrue(host.hitTest(point) === target, "SwiftUI must route empty-header clicks to the native drag view.")
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            XCTAssertTrue(target.acceptsFirstMouse(for: event))
            panel.dragEvent = nil
            target.mouseDown(with: event)
            XCTAssertTrue(panel.dragEvent === event)
        }
    }
}

private final class DragRecordingPanel: NSPanel {
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
}

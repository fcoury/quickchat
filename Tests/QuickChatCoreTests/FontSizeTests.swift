import AppKit
import XCTest
@testable import QuickChat

final class FontSizeTests: XCTestCase {
    @MainActor func testFontShortcutsModifiersBoundsAndPersistence() async throws {
        let suite = "QuickChat-FontSizeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = WindowState(defaults: defaults)
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
        }
        XCTAssertEqual(state.chatFontSize, 15)
        XCTAssertFalse(state.handleFontSizeShortcut(try key("=", [])))
        XCTAssertFalse(state.handleFontSizeShortcut(try key("=", [.command, .option])))
        XCTAssertTrue(state.handleFontSizeShortcut(try key("+", [.command, .shift])))
        XCTAssertEqual(state.chatFontSize, 16, "Command-Shift-Plus must not be rejected by a command-only modifier check.")
        XCTAssertTrue(state.handleFontSizeShortcut(try key("=", [.command, .capsLock])))
        XCTAssertEqual(state.chatFontSize, 17)
        XCTAssertTrue(state.handleFontSizeShortcut(try key("-", [.command, .numericPad])))
        XCTAssertEqual(state.chatFontSize, 16)
        state.settingsVisible = true
        XCTAssertFalse(state.handleFontSizeShortcut(try key("=")))
        XCTAssertEqual(state.chatFontSize, 16)
        state.settingsVisible = false
        for _ in 0..<30 { _ = state.handleFontSizeShortcut(try key("=")) }
        XCTAssertEqual(state.chatFontSize, 26)
        for _ in 0..<30 { _ = state.handleFontSizeShortcut(try key("-")) }
        XCTAssertEqual(state.chatFontSize, 12)
        XCTAssertEqual(WindowState(defaults: defaults).chatFontSize, 12)
        XCTAssertTrue(state.handleFontSizeShortcut(try key("0")))
        XCTAssertEqual(state.chatFontSize, 15)
        XCTAssertEqual(WindowState(defaults: defaults).chatFontSize, 15)
    }
}

import AppKit
import XCTest
@testable import QuickChat

final class PasteTests: XCTestCase {
    @MainActor func testImageOnlyClipboardEnablesPasteAndDeliversPNG() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
        board.declareTypes([.png], owner: nil)
        XCTAssertTrue(board.setData(png, forType: .png))
        XCTAssertNil(board.string(forType: .string))
        let editor = PasteTextView(); editor.isRichText = false; editor.imagePasteboard = board
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        XCTAssertTrue(editor.validateUserInterfaceItem(paste), "Plain-text AppKit editors otherwise disable image-only paste before our handler runs.")
        var image: NSImage?
        editor.onImage = { image = $0 }
        editor.paste(nil)
        XCTAssertEqual(image?.size.width, 2)
        XCTAssertEqual(image?.size.height, 2)
        XCTAssertTrue(editor.string.isEmpty, "Images should become attachments, not text-container contents.")
    }

    @MainActor func testInvalidClipboardShowsErrorInsteadOfSilentlyDoingNothing() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let editor = PasteTextView(); editor.imagePasteboard = board
        var error: String?
        editor.onPasteError = { error = $0 }
        editor.paste(nil)
        XCTAssertNotNil(error)
    }
}

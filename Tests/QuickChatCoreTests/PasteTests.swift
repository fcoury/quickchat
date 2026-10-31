import AppKit
import QuickChatCore
import XCTest
@testable import QuickChat

final class PasteTests: XCTestCase {
    @MainActor func testCopyConversationUsesRequestedHistoryRowAndOmitsDraft() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ChatStore(demo: true)
        await store.load()
        let active = try XCTUnwrap(store.current)
        var archived = Conversation()
        archived.title = "Layout review"
        archived.draft = "Unsent follow-up"
        let screenshot = Attachment(filename: "screen.png", width: 640, height: 480)
        var reply = Message(role: "assistant", text: "Try this:\n```swift\nlayout()\n```")
        reply.citations = [Citation(url: "https://example.com/layout", title: "Layout guide")]
        archived.messages = [Message(role: "user", text: "Review this.", attachments: [screenshot]), reply]
        store.chats.append(archived)

        XCTAssertTrue(store.copyConversation(archived.id, to: board))
        let expected = """
        Layout review

        You:
        [Screenshot, 640 × 480]
        Review this.

        Assistant:
        Try this:
        ```swift
        layout()
        ```
        Layout guide — https://example.com/layout
        """
        XCTAssertEqual(board.string(forType: .string), expected)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        let html = try XCTUnwrap(board.string(forType: .html))
        XCTAssertTrue(html.contains("<strong>You:</strong>"))
        XCTAssertTrue(html.contains("<p>[Screenshot, 640 × 480]</p>"))
        XCTAssertTrue(html.contains("<pre><code>layout()\n</code></pre>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com/layout\">Layout guide</a>"))
        XCTAssertFalse(html.contains(archived.draft))
        XCTAssertEqual(store.selectedID, active.id)
        let empty = try XCTUnwrap(store.chats.first(where: { $0.messages.isEmpty }))
        XCTAssertFalse(store.copyConversation(empty.id, to: board))
        XCTAssertEqual(board.string(forType: .string), expected)
    }

    @MainActor func testReplyCopiesMarkdownAndSemanticHTMLOnOneItem() throws {
        let markdown = """
        ### Update

        **Ready** with *emphasis*, ~~removed~~, `a < b` and [docs](https://example.com/).

        3. First
           - Nested

        > Quoted

        ```swift
          x < y
        ```

        | Name | Value |
        | --- | --- |
        | One | 2 |
        """
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(ChatClipboard(reply: Message(role: "assistant", text: markdown)).write(to: board))
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(item.string(forType: .string), markdown)
        let html = try XCTUnwrap(item.string(forType: .html))
        for fragment in ["<h3>Update</h3>", "<strong>Ready</strong>", "<em>emphasis</em>",
                         "<s>removed</s>", "<code>a &lt; b</code>", "<a href=\"https://example.com/\">docs</a>",
                         "<ol start=\"3\"><li>", "<ul><li>", "<blockquote>", "<pre><code>  x &lt; y\n</code></pre>",
                         "<th>Name</th>", "<td>2</td>"] {
            XCTAssertTrue(html.contains(fragment), "Missing \(fragment) in \(html)")
        }
    }

    func testRichTranscriptKeepsTurnsSeparateAndEscapesUntrustedContent() {
        var chat = Conversation()
        chat.title = "<Title>"
        chat.messages = [
            Message(role: "assistant", text: "Literal HTML:\n\n<script>hello()</script>\n\n![diagram](https://example.com/tracker) [bad](javascript:alert)\n\n```\nunfinished"),
            Message(role: "user", text: "**literal**\n<tag> & text"),
        ]
        let html = ChatClipboard(conversation: chat).html
        XCTAssertTrue(html.contains("&lt;Title&gt;"))
        XCTAssertTrue(html.contains("&lt;script&gt;hello()&lt;/script&gt;"))
        XCTAssertTrue(html.contains("diagram"))
        XCTAssertFalse(html.contains("https://example.com/tracker"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertTrue(html.contains("</code></pre>\n<p><strong>You:</strong></p>\n<p>**literal**<br>&lt;tag&gt; &amp; text</p>"))
    }

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

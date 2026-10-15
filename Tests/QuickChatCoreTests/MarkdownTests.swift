import AppKit
import SwiftUI
import XCTest
@testable import QuickChat

final class MarkdownTests: XCTestCase {
    @MainActor func testNativeLayoutAtDefaultAndLargeFontSizes() async throws {
        _ = NSApplication.shared
        let sample = """
        Here are a few **useful snippets**, with `inline code` and a [documentation link](https://example.com). The explanation stays easy to scan in a wide window, while the code below uses the extra room for longer lines. Resize the window or adjust the text size to see how the layout adapts.

        ### Python — Remove duplicates while preserving order

        ```python
        items = ["apple", "banana", "apple", "cherry"]
        unique = list(dict.fromkeys(items))

        print(unique)  # ['apple', 'banana', 'cherry']
        ```

        ### JavaScript — Count occurrences

        ```javascript
        const counts = items.reduce((result, item) => {
          result[item] = (result[item] ?? 0) + 1;
          return result;
        }, {});
        ```

        ### A few details

        1. The first example keeps the original order.
           - Repeated items appear only once.
        2. The second counts every occurrence.

        > These examples run locally. Adjust the input to suit your task.

        | Language | Purpose |
        | --- | --- |
        | Python | Remove duplicates |
        | JavaScript | Count occurrences |
        """
        for (width, font) in [(CGFloat(640), CGFloat(15)), (1008, 15), (640, 26)] {
            let host = NSHostingView(rootView: MarkdownText(text: sample, fontSize: font)
                .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color.white.opacity(0.92)).background(Theme.background).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1, "Code and tables must not widen the message container.")
            XCTAssertTrue(size.height.isFinite && size.height > 100)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["QUICKCHAT_RENDER_EVIDENCE_DIR"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown-\(Int(width))w-\(Int(font))pt.png"))
            }
        }
    }

    func testHeadingsInlineStylesAndNestedListsHaveSeparateBlocks() throws {
        let blocks = MarkdownBlock.parse("### A heading\n\nA **bold** word and `inline code`.\n\n3. First\n   - Nested\n4. Second\n\n> A quote")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0].kind, .header(level: 3))
        XCTAssertEqual(String(blocks[0].content.characters), "A heading")
        XCTAssertEqual(String(blocks[1].content.characters), "A bold word and inline code.")
        XCTAssertTrue(blocks[1].content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(blocks[1].content.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertEqual(blocks[2].kind, .orderedList)
        let first = try XCTUnwrap(blocks[2].children.first)
        XCTAssertEqual(first.kind, .listItem(ordinal: 3))
        XCTAssertEqual(first.children.map(\.kind), [.paragraph, .unorderedList])
        XCTAssertEqual(blocks[3].kind, .blockQuote)
    }

    func testCodeFencesPreserveSourceAndHandleIncompleteStreaming() throws {
        let source = "    print(\"``` isn't a fence here 👋\")\n\n"
        for opening in ["~~~~python", "````python"] {
            let closed = MarkdownBlock.parse(opening + "\n" + source + String(opening.prefix(4)))
            let block = try XCTUnwrap(closed.first)
            XCTAssertEqual(block.kind, .codeBlock(languageHint: "python"))
            XCTAssertEqual(String(block.content.characters), source)
        }
        let partial = try XCTUnwrap(MarkdownBlock.parse("Before\n\n```swift\nlet value = \"still streaming").last)
        XCTAssertEqual(partial.kind, .codeBlock(languageHint: "swift"))
        XCTAssertTrue(String(partial.content.characters).contains("let value = \"still streaming"))
    }

    func testTableHeadersAlignmentAndLinksRemainStructured() throws {
        let block = try XCTUnwrap(MarkdownBlock.parse("| Name | Value |\n| --- | ---: |\n| [Docs](https://example.com) | 42 |").first)
        guard case .table(let columns) = block.kind else { return XCTFail("Expected a table") }
        XCTAssertEqual(columns.map(\.alignment), [.left, .right])
        XCTAssertEqual(block.children.map(\.kind), [.tableHeaderRow, .tableRow(rowIndex: 1)])
        let cell = try XCTUnwrap(block.children.last?.children.first)
        XCTAssertEqual(String(cell.content.characters), "Docs")
        XCTAssertEqual(cell.content.runs.first?.link?.absoluteString, "https://example.com")
    }

    func testHighlightingPreservesUnicodeAndDoesNotTreatStringContentsAsComments() throws {
        let code = "return \"https://example.com/#café 👋\" # comment\nvalue = 42\n"
        let result = CodeHighlighting.highlight(code, language: "python")
        XCTAssertEqual(String(result.characters), code)
        let runs = Array(result.runs)
        func color(containing text: String) throws -> Color {
            try XCTUnwrap(runs.first { String(result[$0.range].characters).contains(text) }?.foregroundColor)
        }
        XCTAssertNotEqual(try color(containing: "https://"), try color(containing: "# comment"))
        XCTAssertNotEqual(try color(containing: "return"), try color(containing: "42"))
        XCTAssertTrue(CodeHighlighting.highlight(code, language: "unknown").runs.allSatisfy { $0.foregroundColor == nil })
        XCTAssertTrue(CodeHighlighting.highlight(String(repeating: code, count: 3000), language: "python").runs.allSatisfy { $0.foregroundColor == nil })
    }
}

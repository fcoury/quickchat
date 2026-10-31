import AppKit
import QuickChatCore

/// Two representations of one pasteboard item. The receiving app chooses which to paste.
struct ChatClipboard {
    let text: String
    let html: String

    init(reply: Message) {
        text = reply.text
        html = Self.replyHTML(reply)
    }

    init(conversation: Conversation) {
        var transcript = [conversation.title]
        var blocks = ["<h1>\(escaped(conversation.title))</h1>"]
        for message in conversation.messages {
            let speaker = message.role == "user" ? "You" : message.role.capitalized
            var lines = ["\(speaker):"]
            blocks.append("<p><strong>\(escaped(speaker)):</strong></p>")
            func appendLiteral(_ line: String) {
                lines.append(line)
                blocks.append(paragraph(line))
            }
            for attachment in message.attachments {
                appendLiteral("[Screenshot, \(attachment.width) × \(attachment.height)]")
            }
            if !message.text.isEmpty {
                lines.append(message.text)
                blocks.append(message.role == "assistant" ? Self.markdownHTML(message.text) : paragraph(message.text))
            }
            if let error = message.error { appendLiteral(error) }
            for source in message.citations {
                guard let url = source.safeURL else { continue }
                lines.append("\(source.title) — \(url.absoluteString)")
                blocks.append(Self.sourceLink(source.title, url))
            }
            transcript.append(lines.joined(separator: "\n"))
        }
        text = transcript.joined(separator: "\n\n")
        html = blocks.joined(separator: "\n")
    }

    @MainActor func write(to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(Data(("<meta charset=\"utf-8\">" + html).utf8), forType: .html),
              item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static func replyHTML(_ message: Message) -> String {
        let sources = message.citations.compactMap { citation in
            citation.safeURL.map { sourceLink(citation.title, $0) }
        }
        return ([markdownHTML(message.text)] + sources).joined(separator: "\n")
    }

    private static func sourceLink(_ title: String, _ url: URL) -> String {
        "<p><a href=\"\(escaped(url.absoluteString))\">\(escaped(title.isEmpty ? url.absoluteString : title))</a></p>"
    }

    private static func markdownHTML(_ markdown: String) -> String {
        MarkdownBlock.parse(markdown).map { $0.clipboardHTML }.joined(separator: "\n")
    }
}

private func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func paragraph(_ literal: String) -> String {
    "<p>\(escaped(literal).replacingOccurrences(of: "\n", with: "<br>"))</p>"
}

private extension MarkdownBlock {
    var clipboardHTML: String {
        let tag: String
        switch kind {
        case .header(let level): tag = "h\(level)"
        case .paragraph: tag = "p"
        case .unorderedList: tag = "ul"
        case .orderedList:
            let start: String
            if case .listItem(let ordinal) = children.first?.kind, ordinal != 1 {
                start = " start=\"\(ordinal)\""
            } else { start = "" }
            return "<ol\(start)>\(childrenHTML)</ol>"
        case .listItem: tag = "li"
        case .blockQuote: tag = "blockquote"
        case .codeBlock: return "<pre><code>\(escaped(String(content.characters)))</code></pre>"
        case .thematicBreak: return "<hr>"
        case .table: tag = "table"
        case .tableRow, .tableHeaderRow:
            let cellTag = kind == .tableHeaderRow ? "th" : "td"
            let cells = children.map { "<\(cellTag)>\($0.inlineHTML)</\(cellTag)>" }
            return "<tr>\(cells.joined())</tr>"
        default: return inlineHTML + childrenHTML
        }
        return "<\(tag)>\(inlineHTML)\(childrenHTML)</\(tag)>"
    }

    var childrenHTML: String { children.map { $0.clipboardHTML }.joined() }

    var inlineHTML: String {
        content.runs.map { run in
            let style = run.inlinePresentationIntent ?? []
            if style.contains(.lineBreak) { return "<br>" }
            var value = escaped(String(content[run.range].characters))
            if style.contains(.code) { value = "<code>\(value)</code>" }
            if style.contains(.stronglyEmphasized) { value = "<strong>\(value)</strong>" }
            if style.contains(.emphasized) { value = "<em>\(value)</em>" }
            if style.contains(.strikethrough) { value = "<s>\(value)</s>" }
            if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased()) {
                value = "<a href=\"\(escaped(link.absoluteString))\">\(value)</a>"
            }
            return value
        }.joined()
    }
}

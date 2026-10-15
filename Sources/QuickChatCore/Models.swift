import Foundation

public struct Attachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var width: Int
    public var height: Int
    public init(id: UUID = UUID(), filename: String, width: Int, height: Int) {
        self.id = id; self.filename = filename; self.width = width; self.height = height
    }
}

public struct Citation: Codable, Equatable, Identifiable, Sendable {
    public var url: String
    public var title: String
    public var start: Int
    public var end: Int
    public var id: String { "\(url):\(start):\(end)" }
    public init(url: String, title: String, start: Int = 0, end: Int = 0) {
        self.url = url; self.title = title; self.start = start; self.end = end
    }
    public var safeURL: URL? {
        guard let value = URL(string: url), ["https", "http"].contains(value.scheme?.lowercased() ?? "") else { return nil }
        return value
    }
}

public enum MessageStatus: String, Codable, Sendable { case complete, streaming, stopped, failed }
public struct Message: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var attachments: [Attachment] = []
    public var citations: [Citation] = []
    public var status: MessageStatus = .complete
    public var error: String?
    public init(role: String, text: String, attachments: [Attachment] = [], status: MessageStatus = .complete) {
        self.role = role; self.text = text; self.attachments = attachments; self.status = status
    }
    public var displayText: String {
        var scalars = Array(text.unicodeScalars)
        // Responses annotation offsets are Unicode code points, not grapheme clusters.
        for (index, citation) in citations.enumerated().sorted(by: { $0.element.start > $1.element.start }) {
            guard let url = citation.safeURL, citation.start >= 0, citation.end >= citation.start,
                  citation.end <= scalars.count else { continue }
            let link = " [\(index + 1)](\(url.absoluteString))"
            scalars.replaceSubrange(citation.start..<citation.end, with: link.unicodeScalars)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

public struct Conversation: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title = "New chat"
    public var updatedAt = Date()
    public var model = ""
    public var draft = ""
    public var draftAttachments: [Attachment] = []
    public var messages: [Message] = []
    public var searchEnabled = true
    public init(model: String = "") { self.model = model }
}

public struct AvailableModel: Decodable, Identifiable, Sendable {
    public var slug: String
    public var display_name: String
    public var visibility: String?
    public var id: String { slug }
    public init(slug: String, displayName: String) { self.slug = slug; self.display_name = displayName }
}

public struct AppError: LocalizedError, Sendable {
    public let message: String
    public let code: String?
    public init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}

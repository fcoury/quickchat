import Foundation

public actor HistoryStore {
    public nonisolated let root: URL
    public nonisolated var images: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public init(root: URL) { self.root = root }

    public func load() throws -> [Conversation] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var chats: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            var chat = try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: file))
            for i in chat.messages.indices where chat.messages[i].status == .streaming {
                chat.messages[i].status = .stopped
                chat.messages[i].error = "Response interrupted when QuickChat closed."
            }
            chats.append(chat)
        }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func save(_ chat: Conversation) throws {
        try prepare()
        let url = root.appendingPathComponent(chat.id.uuidString + ".json")
        try JSONEncoder().encode(chat).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func delete(_ chat: Conversation) throws {
        let url = root.appendingPathComponent(chat.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let all = chat.draftAttachments + chat.messages.flatMap(\.attachments)
        for attachment in all { try? FileManager.default.removeItem(at: imageURL(attachment)) }
    }
    public func storeImage(_ data: Data, width: Int, height: Int) throws -> Attachment {
        try prepare()
        let attachment = Attachment(filename: UUID().uuidString + ".png", width: width, height: height)
        let url = imageURL(attachment)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return attachment
    }
    public nonisolated func imageURL(_ attachment: Attachment) -> URL {
        images.appendingPathComponent(URL(fileURLWithPath: attachment.filename).lastPathComponent)
    }
    public func removeImage(_ attachment: Attachment) { try? FileManager.default.removeItem(at: imageURL(attachment)) }
    private func prepare() throws {
        for url in [root, images] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

import AppKit
import QuickChatCore

@MainActor final class ChatStore: ObservableObject {
    @Published var chats: [Conversation] = []
    @Published var selectedID: UUID?
    @Published var models: [AvailableModel] = []
    @Published var loadingModels = false
    @Published var runningID: UUID?
    @Published var searching = false
    @Published var error: String?
    @Published var focusRequest = UUID()
    let history: HistoryStore
    let demo: Bool
    private var responseTask: Task<Void, Never>?
    private var saves: [UUID: Task<Void, Never>] = [:]
    private var lastStreamSave = Date.distantPast
    private var loaded = false
    private var modelRequest = UUID()
    private var attachmentDestinations: [UUID: UUID] = [:]
    var current: Conversation? { chats.first { $0.id == selectedID } }
    var busy: Bool { runningID != nil }
    var selectedModelName: String { models.first { $0.slug == current?.model }?.display_name ?? (current?.model.isEmpty == false ? current!.model : "Choose model") }
    init(demo: Bool, history: HistoryStore? = nil) {
        self.demo = demo
        let root = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-Demo-\(ProcessInfo.processInfo.processIdentifier)") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuickChat")
        self.history = history ?? HistoryStore(root: root)
    }
    func load() async {
        guard !loaded else { return }; loaded = true
        if demo {
            models = [AvailableModel(slug: "demo", displayName: "Preview model")]
            var chat = Conversation(model: "demo"); chat.title = "Rewrite a follow-up"
            chat.messages = [Message(role: "user", text: "Make this friendlier:\nCan you send the update today? I need it before 3."),
                Message(role: "assistant", text: "Could you send me an update today when you have a chance? It would be great to have it before 3. Thanks!")]
            chat.draft = "Make it a little more casual"
            var second = Conversation(model: "demo"); second.title = "Explain async / await"
            second.updatedAt = Date().addingTimeInterval(-86400)
            chats = [chat, second]; selectedID = chat.id
            return
        }
        do {
            chats = try await history.load()
            let saved = UserDefaults.standard.string(forKey: "selectedChat").flatMap(UUID.init(uuidString:))
            selectedID = chats.first(where: { $0.id == saved })?.id ?? chats.first?.id
        } catch { self.error = "Could not load saved chats. Existing files were preserved. \(error.localizedDescription)" }
        if chats.isEmpty { newChat() }
    }
    func refreshModels(auth: AuthService) async {
        guard auth.connected, !demo else { return }
        let request = UUID(); modelRequest = request
        loadingModels = true; models = []
        defer { if request == modelRequest { loadingModels = false } }
        do {
            let token = try await auth.token()
            let fetched = try await ResponsesClient.models(token: token)
            guard request == modelRequest, auth.connected else { return }
            models = fetched
            if models.isEmpty { throw AppError("This ChatGPT account returned no available models.") }
            if let chat = current, !models.contains(where: { $0.slug == chat.model }) {
                let saved = UserDefaults.standard.string(forKey: "defaultModel")
                setModel(models.first(where: { $0.slug == saved })?.slug ?? models[0].slug)
            }
        } catch { self.error = error.localizedDescription }
    }
    func newChat() {
        let model = current?.model ?? models.first?.slug ?? ""
        var chat = Conversation(model: model)
        if let index = chats.firstIndex(where: { $0.id == selectedID }) {
            let previousID = chats[index].id
            chat.draft = chats[index].draft
            chat.draftAttachments = chats[index].draftAttachments
            chat.searchEnabled = chats[index].searchEnabled
            // Move the draft: two chats must not own the same screenshot files.
            chats[index].draft = ""; chats[index].draftAttachments = []
            attachmentDestinations = attachmentDestinations.mapValues { $0 == previousID ? chat.id : $0 }
            scheduleSave(previousID)
        }
        chats.insert(chat, at: 0); select(chat.id); scheduleSave(chat.id)
    }
    func select(_ id: UUID) {
        selectedID = id
        if !demo { UserDefaults.standard.set(id.uuidString, forKey: "selectedChat") }
        focusRequest = UUID()
    }
    @discardableResult
    func copyConversation(_ id: UUID?, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let chat = chats.first(where: { $0.id == id }), !chat.messages.isEmpty else { return false }
        guard ChatClipboard(conversation: chat).write(to: pasteboard) else {
            error = "Could not copy the conversation to the clipboard."
            return false
        }
        return true
    }
    func setDraft(_ text: String) { mutate { $0.draft = text }; if let selectedID { scheduleSave(selectedID) } }
    func setModel(_ model: String) {
        mutate { $0.model = model }; if !demo { UserDefaults.standard.set(model, forKey: "defaultModel") }
        if let selectedID { scheduleSave(selectedID) }
    }
    func setSearch(_ enabled: Bool) { mutate { $0.searchEnabled = enabled }; if let selectedID { scheduleSave(selectedID) } }
    func delete(_ id: UUID) {
        guard id != runningID, let chat = chats.first(where: { $0.id == id }) else { return }
        saves[id]?.cancel(); saves[id] = nil
        Task {
            do {
                try await history.delete(chat)
                chats.removeAll { $0.id == id }
                if selectedID == id { if let first = chats.first { select(first.id) } else { newChat() } }
            } catch { self.error = error.localizedDescription }
        }
    }
    func attach(_ image: NSImage) {
        guard let id = selectedID else { return }
        guard (current?.draftAttachments.count ?? 0) < 4 else { error = "You can attach up to four screenshots per message."; return }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width <= 16000, cg.height <= 16000,
              cg.width * cg.height <= 50_000_000 else { error = "This image is too large. Paste a smaller screenshot (up to 50 megapixels)."; return }
        let request = UUID()
        attachmentDestinations[request] = id
        // Keep the original pixels so small text remains readable; conversion happens off the main thread.
        Task {
            defer { attachmentDestinations[request] = nil }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    guard let data = rep.representation(using: .png, properties: [:]), data.count <= 20_000_000 else {
                        throw AppError("The screenshot is too large. Use an image under 20 MB.")
                    }
                    return data
                }.value
                let attachment = try await history.storeImage(data, width: cg.width, height: cg.height)
                guard let destination = attachmentDestinations[request],
                      let index = chats.firstIndex(where: { $0.id == destination }), chats[index].draftAttachments.count < 4 else {
                    await history.removeImage(attachment); return
                }
                chats[index].draftAttachments.append(attachment); scheduleSave(destination); focusRequest = UUID()
            } catch { self.error = error.localizedDescription }
        }
    }
    func removeAttachment(_ attachment: Attachment) {
        mutate { $0.draftAttachments.removeAll { $0.id == attachment.id } }
        if let selectedID { scheduleSave(selectedID) }
        Task { await history.removeImage(attachment) }
    }
    func send(auth: AuthService) {
        guard !busy, let chat = current, !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draftAttachments.isEmpty else { return }
        guard demo || auth.connected else { error = "Continue with ChatGPT in Settings to send a message."; return }
        guard models.contains(where: { $0.slug == chat.model }) else { error = "Choose an available model first."; return }
        mutate {
            if $0.messages.isEmpty { $0.title = String(($0.draft.isEmpty ? "Screenshot question" : $0.draft).prefix(64)).replacingOccurrences(of: "\n", with: " ") }
            $0.messages.append(Message(role: "user", text: $0.draft, attachments: $0.draftAttachments))
            $0.draft = ""; $0.draftAttachments = []; $0.updatedAt = Date()
        }
        startResponse(auth: auth)
    }
    func retry(auth: AuthService) {
        guard !busy, let chat = current, !chat.messages.isEmpty else { return }
        guard demo || auth.connected else { error = "Sign in with ChatGPT before retrying."; return }
        mutate { if $0.messages.last?.role == "assistant" { $0.messages.removeLast() } }
        startResponse(auth: auth)
    }
    func stop() { responseTask?.cancel() }
    func flush() async {
        saves.values.forEach { $0.cancel() }; saves.removeAll()
        for chat in chats { do { try await history.save(chat) } catch { self.error = error.localizedDescription } }
    }
    private func startResponse(auth: AuthService) {
        guard let requestChat = current else { return }
        let id = requestChat.id
        mutate { $0.messages.append(Message(role: "assistant", text: "", status: .streaming)) }
        runningID = id; searching = false; error = nil; focusRequest = UUID()
        responseTask = Task {
            defer { runningID = nil; searching = false; responseTask = nil; scheduleSave(id) }
            do {
                if let chat = chats.first(where: { $0.id == id }) { try await history.save(chat) }
                if demo {
                    for word in "Hey! Could you send me an update today? Before 3 would be great. Thanks!".split(separator: " ") {
                        try await Task.sleep(for: .milliseconds(65))
                        apply(.delta(String(word) + " "), to: id)
                    }
                    apply(.finished(text: "Hey! Could you send me an update today? Before 3 would be great. Thanks!", citations: []), to: id)
                } else {
                    let token = try await auth.token()
                    let images = history.images
                    let body = try await Task.detached(priority: .userInitiated) { try ResponsesClient.body(chat: requestChat, images: images) }.value
                    try await ResponsesClient.stream(token: token, body: body) { update in await self.apply(update, to: id) }
                }
            } catch {
                guard let i = chats.firstIndex(where: { $0.id == id }), let j = chats[i].messages.indices.last else { return }
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                chats[i].messages[j].status = cancelled ? .stopped : .failed
                chats[i].messages[j].error = cancelled ? "Response stopped." : error.localizedDescription
            }
        }
    }
    private func apply(_ update: StreamUpdate, to id: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == id }), let j = chats[i].messages.indices.last else { return }
        switch update {
        case .delta(let text): chats[i].messages[j].text += text; searching = false
        case .searching: searching = true
        case .finished(let text, let citations):
            chats[i].messages[j].text = text; chats[i].messages[j].citations = citations; chats[i].messages[j].status = .complete; searching = false
        }
        if Date().timeIntervalSince(lastStreamSave) > 2 { lastStreamSave = Date(); scheduleSave(id) }
    }
    private func mutate(_ body: (inout Conversation) -> Void) {
        if let i = chats.firstIndex(where: { $0.id == selectedID }) { body(&chats[i]) }
    }
    private func scheduleSave(_ id: UUID) {
        saves[id]?.cancel()
        saves[id] = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let chat = chats.first(where: { $0.id == id }) else { return }
                try await history.save(chat); saves[id] = nil
            } catch is CancellationError {} catch { self.error = "Could not save chat: \(error.localizedDescription)" }
        }
    }
}

import Foundation

public enum StreamUpdate: Sendable {
    case delta(String), searching, finished(text: String, citations: [Citation])
}

public struct ResponseAccumulator {
    public private(set) var text = ""
    public private(set) var completed = false
    public init() {}
    public mutating func consume(_ data: Data) throws -> StreamUpdate? {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = event["type"] as? String ?? ""
        switch type {
        case "response.output_text.delta":
            let delta = event["delta"] as? String ?? ""
            text += delta
            return .delta(delta)
        case "response.web_search_call.in_progress", "response.web_search_call.searching": return .searching
        case "response.completed":
            let response = event["response"] as? [String: Any] ?? [:]
            let output = response["output"] as? [[String: Any]] ?? []
            var final = ""
            var citations: [Citation] = []
            for item in output where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    guard let partText = (part["text"] ?? part["refusal"]) as? String else { continue }
                    if !final.isEmpty { final += "\n\n" }
                    let offset = final.unicodeScalars.count
                    final += partText
                    for a in part["annotations"] as? [[String: Any]] ?? [] where a["type"] as? String == "url_citation" {
                        guard let url = a["url"] as? String else { continue }
                        citations.append(Citation(url: url, title: a["title"] as? String ?? url,
                            start: offset + (a["start_index"] as? Int ?? 0), end: offset + (a["end_index"] as? Int ?? 0)))
                    }
                }
            }
            completed = true
            if !final.isEmpty { text = final }
            return .finished(text: text, citations: citations)
        case "response.failed", "response.incomplete":
            let response = event["response"] as? [String: Any] ?? [:]
            if let error = response["error"] as? [String: Any] { throw Self.apiError(error) }
            throw AppError("The response was incomplete. Your conversation is saved; you can retry.")
        case "error": throw Self.apiError(event["error"] as? [String: Any] ?? event)
        default: return nil
        }
    }
    public func requireCompletion() throws {
        if !completed { throw AppError("The connection ended before the response finished. Your partial answer is saved.") }
    }
    public static func apiError(_ error: [String: Any], status: Int? = nil, requestID: String? = nil) -> AppError {
        let code = error["code"] as? String ?? error["error"] as? String
        var message = error["message"] as? String ?? error["detail"] as? String ?? "Request failed\(status.map { " (HTTP \($0))" } ?? "")."
        if code == "subscription_sharing_usage_limit_exceeded" { message = "Your ChatGPT plan or app usage limit was reached. Open Manage usage in settings." }
        if code == "subscription_sharing_unsupported_capability" { message += " Try turning web search off or choosing another model." }
        if let requestID { message += "\nRequest ID: \(requestID)" }
        return AppError(message, code: code)
    }
}

/// A bounded SSE decoder. Retains multi-line data until the blank event delimiter.
public struct SSEDecoder {
    private var line = Data()
    private var dataLines: [String] = []
    public init() {}
    public mutating func append(_ byte: UInt8) throws -> Data? {
        guard byte == 10 else {
            if line.count > 8_000_000 { throw AppError("The server sent an oversized stream event.") }
            line.append(byte); return nil
        }
        let value = String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true) }
            let data = dataLines.joined(separator: "\n")
            return data.isEmpty || data == "[DONE]" ? nil : Data(data.utf8)
        }
        if value.hasPrefix("data:") {
            var payload = String(value.dropFirst(5))
            if payload.first == " " { payload.removeFirst() }
            dataLines.append(payload)
        }
        return nil
    }
}

public enum ResponsesClient {
    public static func models(token: String) async throws -> [AvailableModel] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        struct Catalog: Decodable { var models: [AvailableModel] }
        return try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
    }
    public static func body(chat: Conversation, images: URL) throws -> Data {
        var input: [[String: Any]] = []
        for message in chat.messages where !message.text.isEmpty || !message.attachments.isEmpty {
            if message.role == "assistant" {
                input.append(["role": "assistant", "content": message.text])
            } else {
                var content: [[String: Any]] = []
                if !message.text.isEmpty { content.append(["type": "input_text", "text": message.text]) }
                for image in message.attachments {
                    let url = images.appendingPathComponent(URL(fileURLWithPath: image.filename).lastPathComponent)
                    let data = try Data(contentsOf: url)
                    content.append(["type": "input_image", "image_url": "data:image/png;base64," + data.base64EncodedString(), "detail": "auto"])
                }
                input.append(["role": "user", "content": content])
            }
        }
        var body: [String: Any] = ["model": chat.model, "input": input, "store": false, "stream": true,
            "instructions": "You are a helpful assistant in a quick-access macOS chat app. Be concise and direct unless detail is useful. For rewrites, provide the rewritten text without an unnecessary preamble. Use web search when current information or verification would improve the answer; do not search for ordinary rewriting. Format code with fenced code blocks."]
        if chat.searchEnabled { body["tools"] = [["type": "web_search"]] }
        return try JSONSerialization.data(withJSONObject: body)
    }
    public static func stream(token: String, body: Data, onUpdate: @escaping @Sendable (StreamUpdate) async -> Void) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("No HTTP response received.") }
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { if data.count >= 65536 { break }; data.append(byte) }
            try check(data, response)
        }
        var decoder = SSEDecoder()
        var accumulator = ResponseAccumulator()
        var pending = ""
        var lastFlush = Date.distantPast
        for try await byte in bytes {
            try Task.checkCancellation()
            if let data = try decoder.append(byte), let update = try accumulator.consume(data) {
                switch update {
                case .delta(let delta):
                    pending += delta
                    if Date().timeIntervalSince(lastFlush) >= 0.04 {
                        await onUpdate(.delta(pending)); pending = ""; lastFlush = Date()
                    }
                default:
                    if !pending.isEmpty { await onUpdate(.delta(pending)); pending = "" }
                    await onUpdate(update)
                }
                if accumulator.completed { break }
            }
        }
        if !pending.isEmpty { await onUpdate(.delta(pending)) }
        try accumulator.requireCompletion()
    }
    public static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AppError("No HTTP response received.") }
        if !(200..<300).contains(http.statusCode) {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw ResponseAccumulator.apiError(obj["error"] as? [String: Any] ?? obj, status: http.statusCode,
                requestID: http.value(forHTTPHeaderField: "x-request-id"))
        }
    }
}

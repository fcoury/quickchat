import XCTest
import Security
@testable import QuickChatCore

final class CoreTests: XCTestCase {
    func testPKCEKnownVectorAndFormEncoding() {
        XCTAssertEqual(OAuthValidation.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(String(decoding: OAuthValidation.form(["code": "a+b &c"]), as: UTF8.self), "code=a%2Bb%20%26c")
    }
    func testCallbackRejectsStateErrorsDuplicatesAndAccountSwitch() throws {
        func callback(_ query: String, client: String? = nil) throws -> (code: String, client: String) {
            try OAuthValidation.callback(URL(string: "http://127.0.0.1:1234/auth/callback?" + query)!, state: "expected", existingClient: client)
        }
        let ok = try callback("state=expected&code=ok&client_id=oaiapp_test")
        XCTAssertEqual(ok.client, "oaiapp_test")
        XCTAssertThrowsError(try callback("state=wrong&code=ok&client_id=oaiapp_test"))
        XCTAssertThrowsError(try callback("state=expected&error=access_denied&code=ok"))
        XCTAssertThrowsError(try callback("state=expected&state=wrong&code=ok&client_id=oaiapp_test"))
        XCTAssertThrowsError(try callback("state=expected&code=ok&client_id=other", client: "original"))
        XCTAssertThrowsError(try callback("state=expected&code=ok"))
        XCTAssertEqual(try callback("state=expected&code=ok", client: "original").client, "original")
    }
    func testIdentityClaimsFailClosed() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "client", "exp": 2000.0, "sub": "user", "nonce": "nonce"]
        try OAuthValidation.validateClaims(claims, clientID: "client", nonce: "nonce", subject: "user", now: now)
        for (key, value) in [("iss", "https://evil.example"), ("aud", "other"), ("nonce", "wrong"), ("sub", "other")] {
            var invalid = claims; invalid[key] = value
            XCTAssertThrowsError(try OAuthValidation.validateClaims(invalid, clientID: "client", nonce: "nonce", subject: "user", now: now))
        }
        XCTAssertThrowsError(try OAuthValidation.validateClaims(claims, clientID: "client", nonce: "nonce", subject: "user", now: Date(timeIntervalSince1970: 2001)))
    }
    func testJWTRejectsUnsignedAndTamperedToken() throws {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Parse the generated PKCS#1 public key to build an independent test JWKS.
        var offset = 0
        func length() -> Int {
            let first = Int(der[offset]); offset += 1
            if first < 128 { return first }
            var result = 0
            for _ in 0..<(first & 127) { result = result * 256 + Int(der[offset]); offset += 1 }
            return result
        }
        offset += 1; _ = length(); offset += 1
        let nLength = length(); let n = der.subdata(in: offset..<(offset + nLength)); offset += nLength + 1
        let eLength = length(); let e = der.subdata(in: offset..<(offset + eLength))
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "n": OAuthValidation.base64URL(n), "e": OAuthValidation.base64URL(e)]]])
        let header = OAuthValidation.base64URL(Data(#"{"alg":"RS256","kid":"test"}"#.utf8))
        let payload = OAuthValidation.base64URL(Data(#"{"iss":"https://auth.openai.com","aud":"client","sub":"user","exp":9999999999,"nonce":"nonce"}"#.utf8))
        let input = header + "." + payload
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        let token = input + "." + OAuthValidation.base64URL(signature)
        let claims = try OAuthValidation.verifyIDToken(token, jwks: jwks, clientID: "client", nonce: "nonce")
        XCTAssertEqual(claims["sub"] as? String, "user")
        XCTAssertThrowsError(try OAuthValidation.verifyIDToken(input + "." + OAuthValidation.base64URL(Data(repeating: 0, count: signature.count)), jwks: jwks, clientID: "client", nonce: "nonce"))
        XCTAssertThrowsError(try OAuthValidation.verifyIDToken(input + ".", jwks: jwks, clientID: "client", nonce: "nonce"))
    }
    func testSSEMultilineUTF8AndCompletion() throws {
        let stream = ": keepalive\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"Olá 👋\"}\r\n\r\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
        var decoder = SSEDecoder(); var accumulator = ResponseAccumulator()
        for byte in stream.utf8 { if let event = try decoder.append(byte) { _ = try accumulator.consume(event) } }
        try accumulator.requireCompletion()
        XCTAssertEqual(accumulator.text, "Olá 👋")
    }
    func testFailureAfterPartialOutputAndMissingTerminalEvent() throws {
        var accumulator = ResponseAccumulator()
        _ = try accumulator.consume(Data(#"{"type":"response.output_text.delta","delta":"Partial"}"#.utf8))
        XCTAssertThrowsError(try accumulator.requireCompletion())
        XCTAssertThrowsError(try accumulator.consume(Data(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}"#.utf8))) { error in
            XCTAssertEqual((error as? AppError)?.code, "subscription_sharing_usage_limit_exceeded")
        }
        XCTAssertEqual(accumulator.text, "Partial")
        XCTAssertFalse(accumulator.completed)
    }
    func testCitationsPersistAndRejectUnsafeLinks() throws {
        var accumulator = ResponseAccumulator()
        let event = #"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Olá 👋 source","annotations":[{"type":"url_citation","url":"https://example.com","title":"Example","start_index":6,"end_index":12}]}]}]}}"#
        guard case let .finished(text, citations) = try accumulator.consume(Data(event.utf8)) else { return XCTFail("Missing completion") }
        var message = Message(role: "assistant", text: text); message.citations = citations
        XCTAssertTrue(message.displayText.contains("[1](https://example.com)"))
        XCTAssertTrue(message.displayText.hasPrefix("Olá 👋 "))
        XCTAssertNil(Citation(url: "javascript:alert(1)", title: "Bad").safeURL)
    }
    func testHistoryRoundTripDraftImagesAndInterruptedResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(root: root)
        let image = try await history.storeImage(Data([1, 2, 3]), width: 10, height: 20)
        var chat = Conversation(model: "account-model"); chat.draft = "Keep my draft"; chat.draftAttachments = [image]
        chat.messages = [Message(role: "user", text: "Question"), Message(role: "assistant", text: "Partial", status: .streaming)]
        try await history.save(chat)
        let loaded = try await history.load()
        XCTAssertEqual(loaded.first?.draft, chat.draft)
        XCTAssertEqual(loaded.first?.draftAttachments, [image])
        XCTAssertEqual(loaded.first?.messages.last?.status, .stopped)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(chat.id.uuidString + ".json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await history.delete(chat)
        let remaining = try await history.load()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.imageURL(image).path))
    }
    func testRequestReplaysHistoryImageAndSearchPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("shot.png"))
        var chat = Conversation(model: "account-model")
        chat.messages = [Message(role: "user", text: "What is this?", attachments: [Attachment(filename: "shot.png", width: 1, height: 1)]), Message(role: "assistant", text: "An image"), Message(role: "user", text: "Explain")]
        let data = try ResponsesClient.body(chat: chat, images: root)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,AQID")
        XCTAssertNotNil(body["tools"])
        chat.searchEnabled = false
        let off = try XCTUnwrap(JSONSerialization.jsonObject(with: ResponsesClient.body(chat: chat, images: root)) as? [String: Any])
        XCTAssertNil(off["tools"])
    }
}

import Foundation
import CryptoKit
import Security

public enum OAuthValidation {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError("Could not create a secure sign-in request.") }
        return base64URL(Data(bytes))
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ value: String) -> Data? {
        var str = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        str += String(repeating: "=", count: (4 - str.count % 4) % 4)
        return Data(base64Encoded: str)
    }
    public static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    public static func callback(_ url: URL, state: String, existingClient: String?) throws -> (code: String, client: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Reject duplicate security parameters rather than accepting an ambiguous callback.
        for name in ["state", "code", "client_id", "error"] where items.filter({ $0.name == name }).count > 1 {
            throw AppError("The sign-in callback was ambiguous. Please try again.")
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw AppError("The sign-in callback could not be verified.") }
        if let error = value("error") { throw AppError(error == "access_denied" ? "Sign-in was cancelled or permission was declined." : "ChatGPT could not complete sign-in.") }
        guard let code = value("code"), !code.isEmpty else { throw AppError("The sign-in callback had no authorization code.") }
        if let existingClient, let returned = value("client_id"), returned != existingClient {
            throw AppError("The sign-in callback returned a different account registration.")
        }
        guard let client = existingClient ?? value("client_id"), !client.isEmpty, client != "dynamic_agent_client" else {
            throw AppError("ChatGPT did not finish registering this app.")
        }
        return (code, client)
    }
    public static func verifyIDToken(_ token: String, jwks: Data, clientID: String, nonce: String?, subject: String? = nil, now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let payload = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = key["n"] as? String, let e = key["e"] as? String, let modulus = decode(n), let exponent = decode(e) else {
            throw AppError("The ChatGPT identity signature could not be verified.")
        }
        let der = tagged(0x30, integer(modulus) + integer(exponent))
        guard let publicKey = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw AppError("The ChatGPT identity signature is invalid.")
        }
        try validateClaims(claims, clientID: clientID, nonce: nonce, subject: subject, now: now)
        return claims
    }
    public static func validateClaims(_ claims: [String: Any], clientID: String, nonce: String?, subject: String?, now: Date) throws {
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == "https://auth.openai.com", audiences.contains(clientID),
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              let sub = claims["sub"] as? String, !sub.isEmpty else { throw AppError("The ChatGPT identity is expired or belongs to another client.") }
        if audiences.count > 1 && claims["azp"] as? String != clientID { throw AppError("The ChatGPT identity has a different authorized client.") }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 60 { throw AppError("The ChatGPT identity is not valid yet.") }
        if let nonce, claims["nonce"] as? String != nonce { throw AppError("The ChatGPT sign-in nonce did not match.") }
        if let subject, !subject.isEmpty, sub != subject { throw AppError("A different account was returned. Add it as a new account instead.") }
    }
    private static func integer(_ bytes: Data) -> Data {
        var value = Array(bytes)
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return tagged(0x02, Data(value))
    }
    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        var length = Data()
        if value.count < 128 { length.append(UInt8(value.count)) }
        else {
            var count = value.count; var bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + value
    }
}

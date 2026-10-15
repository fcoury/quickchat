import AppKit
import Network
import Security
import QuickChatCore

struct Account: Codable, Identifiable {
    var id: String // Issued OAuth client ID; never the dynamic registration entrypoint.
    var subject: String = ""
    var email: String = "ChatGPT account"
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date = .distantPast
    var scopes: [String] = []
    var mayUsePlan: Bool { scopes.contains("chatgpt.tokens.use.direct") }
    var label: String { "\(email) · \(id.suffix(6))" }
}
struct CredentialVault: Codable {
    var accounts: [Account] = []
    var activeID: String?
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
}

enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.fcoury.QuickChat", kSecAttrAccount as String: "chatgpt-accounts"]
    static func load() throws -> CredentialVault {
        var query = query; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return CredentialVault() }
        guard status == errSecSuccess, let data = result as? Data else { throw AppError("Keychain could not be read (\(status)).") }
        return try JSONDecoder().decode(CredentialVault.self, from: data)
    }
    static func save(_ vault: CredentialVault) throws {
        let data = try JSONEncoder().encode(vault)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError("Credentials could not be saved to Keychain (\(status)).") }
    }
}

@MainActor final class AuthService: ObservableObject {
    @Published private(set) var vault = CredentialVault()
    @Published var signingIn = false
    @Published var error: String?
    @Published var showPlanWelcome = false
    private var callback: LoopbackCallback?
    private var signInTask: Task<Void, Never>?
    private var refreshTask: Task<Account, Error>?
    var active: Account? { vault.accounts.first { $0.id == vault.activeID } }
    var connected: Bool { active?.accessToken != nil && active?.mayUsePlan == true }

    init(preview: Bool = false) {
        if preview { return }
        do { vault = try Keychain.load() } catch { self.error = error.localizedDescription }
    }
    func select(_ id: String) {
        guard !signingIn, refreshTask == nil else { return }
        vault.activeID = id
        do { try Keychain.save(vault) } catch { self.error = error.localizedDescription }
    }
    func signIn(account: Account? = nil) {
        guard !signingIn else { return }
        signingIn = true; error = nil
        signInTask = Task {
            defer { signingIn = false; callback = nil; signInTask = nil }
            do {
                try Keychain.save(vault) // Persist the stable host ID before opening a browser.
                let state = try OAuthValidation.random(), nonce = try OAuthValidation.random(), verifier = try OAuthValidation.random()
                let listener = LoopbackCallback()
                callback = listener
                let returned = try await listener.listen { redirect in
                    var parameters = ["client_id": account?.id ?? "dynamic_agent_client", "ext_agent_host_id": self.vault.hostID,
                        "response_type": "code", "redirect_uri": redirect, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                        "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                        "code_challenge_method": "S256", "code_challenge": OAuthValidation.challenge(verifier)]
                    if account == nil { parameters["agent_name_hint"] = "QuickChat" }
                    if let hint = account?.idToken { parameters["id_token_hint"] = hint }
                    if let email = account?.email { parameters["login_hint"] = email }
                    if account != nil && account?.mayUsePlan == false { parameters["prompt"] = "consent" }
                    var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
                    components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
                    NSWorkspace.shared.open(components.url!)
                }
                let result = try OAuthValidation.callback(returned, state: state, existingClient: account?.id)
                var registration = account ?? Account(id: result.client)
                // Retain the issued registration even if the one-time exchange must be repeated.
                try save(registration, activate: false)
                let tokens = try await Self.tokenRequest(["grant_type": "authorization_code", "client_id": result.client,
                    "code": result.code, "code_verifier": verifier, "redirect_uri": listener.redirectURI, "resource": "https://api.openai.com/v1"])
                guard let idToken = tokens.id_token else { throw AppError("ChatGPT did not return an identity token.") }
                let claims = try await Self.validate(idToken, client: result.client, nonce: nonce, subject: account?.subject)
                registration.subject = claims["sub"] as! String
                registration.email = claims["email"] as? String ?? "ChatGPT account"
                registration = Self.updated(registration, tokens)
                try save(registration, activate: true)
                if registration.mayUsePlan {
                    if !UserDefaults.standard.bool(forKey: "planWelcomeShown") { showPlanWelcome = true }
                } else { error = "Signed in, but ChatGPT plan usage is not enabled. Enable it by signing in again from Settings." }
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancelSignIn() { callback?.cancel(); signInTask?.cancel() }
    func token() async throws -> String {
        guard let account = active, account.mayUsePlan, account.accessToken != nil else { throw AppError("Sign in with ChatGPT and enable plan usage first.") }
        if account.expiresAt.timeIntervalSinceNow > 90 { return account.accessToken! }
        if let refreshTask { return try await refreshTask.value.accessToken! }
        let task = Task<Account, Error> {
            guard let refresh = account.refreshToken else { throw AppError("Please sign in again to renew your ChatGPT session.") }
            do {
                let tokens = try await Self.tokenRequest(["grant_type": "refresh_token", "client_id": account.id,
                    "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
                if let idToken = tokens.id_token { _ = try await Self.validate(idToken, client: account.id, nonce: nil, subject: account.subject) }
                let updated = Self.updated(account, tokens)
                try save(updated, activate: false)
                guard updated.mayUsePlan else { throw AppError("ChatGPT plan usage is no longer enabled. Sign in again from Settings.") }
                return updated
            } catch {
                let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
                if let code = (error as? AppError)?.code, terminal.contains(code) { try clearTokens(account) }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken!
    }
    func signOut() async {
        guard let account = active else { return }
        cancelSignIn()
        // Wait for an in-flight refresh before revoking the latest rotating token.
        if let refreshTask { _ = try? await refreshTask.value }
        let latest = active ?? account
        var revoked = latest.refreshToken == nil
        if let token = latest.refreshToken {
            var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!)
            request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = OAuthValidation.form(["token": token, "token_type_hint": "refresh_token", "client_id": latest.id])
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { revoked = true; break }
            }
        }
        do { try clearTokens(latest) } catch { self.error = error.localizedDescription; return }
        if !revoked { error = "Signed out locally. Remote revocation was not confirmed; disconnect QuickChat in ChatGPT settings to end the remote session." }
    }
    private func clearTokens(_ account: Account) throws {
        var cleared = account
        cleared.accessToken = nil; cleared.refreshToken = nil; cleared.idToken = nil; cleared.scopes = []; cleared.expiresAt = .distantPast
        try save(cleared, activate: false)
    }
    private func save(_ account: Account, activate: Bool) throws {
        var next = vault
        if let i = next.accounts.firstIndex(where: { $0.id == account.id }) { next.accounts[i] = account } else { next.accounts.append(account) }
        if activate { next.activeID = account.id }
        try Keychain.save(next); vault = next
    }
    private struct Tokens: Decodable {
        var access_token: String; var refresh_token: String?; var id_token: String?
        var expires_in: Double; var scope: String?; var token_type: String
    }
    private static func updated(_ account: Account, _ tokens: Tokens) -> Account {
        var account = account
        account.accessToken = tokens.access_token; account.refreshToken = tokens.refresh_token ?? account.refreshToken
        account.idToken = tokens.id_token ?? account.idToken; account.expiresAt = Date().addingTimeInterval(tokens.expires_in)
        if let scope = tokens.scope { account.scopes = scope.split(separator: " ").map(String.init) }
        return account
    }
    private static func tokenRequest(_ values: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthValidation.form(values)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ResponsesClient.check(data, response)
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty, tokens.expires_in > 0 else { throw AppError("ChatGPT returned an invalid token response.") }
        return tokens
    }
    private static func validate(_ token: String, client: String, nonce: String?, subject: String?) async throws -> [String: Any] {
        let (jwks, response) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        try ResponsesClient.check(jwks, response)
        return try OAuthValidation.verifyIDToken(token, jwks: jwks, clientID: client, nonce: nonce, subject: subject)
    }
}

@MainActor final class LoopbackCallback {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private(set) var redirectURI = ""
    func listen(open: @escaping (String) -> Void) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port else { self.finish(.failure(AppError("Could not open the sign-in callback."))); return }
                                self.redirectURI = "http://127.0.0.1:\(port.rawValue)/auth/callback"
                                open(self.redirectURI)
                            case .failed: self.finish(.failure(AppError("Could not start the local sign-in callback.")))
                            default: break
                            }
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.receive(connection) } }
                    listener.start(queue: .main)
                    timeout = Task { try? await Task.sleep(for: .seconds(300)); if !Task.isCancelled { self.finish(.failure(AppError("Sign-in timed out. Please try again."))) } }
                } catch { finish(.failure(error)) }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func receive(_ connection: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { connections.append(connection); connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                let bytes = buffer + (data ?? Data())
                guard bytes.count <= 32768, error == nil else { connection.cancel(); return }
                guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, buffer: bytes) } else { connection.cancel() }; return
                }
                let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", let base = URLComponents(string: self.redirectURI),
                      let url = URL(string: "http://127.0.0.1:\(base.port!)\(parts[1])"), url.path == "/auth/callback" else { connection.cancel(); return }
                let html = "<html><body style='font:17px -apple-system;padding:48px'><h2>Return to QuickChat</h2><p>QuickChat is checking your sign-in. You can close this tab.</p></body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(html)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(.success(url), keepConnections: true)
            }
        }
    }
    private func finish(_ result: Result<URL, Error>, keepConnections: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); listener?.cancel()
        if !keepConnections { connections.forEach { $0.cancel() } }
        connections.removeAll(); continuation.resume(with: result)
    }
}

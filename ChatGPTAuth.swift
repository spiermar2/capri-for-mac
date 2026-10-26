import AppKit
import Foundation
import Network
import Security
import CryptoKit
import LocalAuthentication

// Official public-client flow:
// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
// This module never reads credentials belonging to Codex or another application.

enum ChatGPTAuthError: LocalizedError, Equatable {
    case signedOut, busy, cancelled, timedOut, browserUnavailable, listenerUnavailable
    case invalidCallback, denied, incompleteRegistration, identityMismatch
    case invalidToken, malformedResponse, permissionMissing, network, storage
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Continue with ChatGPT in Settings to connect your account."
        case .busy: return "A ChatGPT sign-in is already in progress."
        case .cancelled: return "ChatGPT sign-in was cancelled."
        case .timedOut: return "ChatGPT sign-in timed out. Please try again."
        case .browserUnavailable: return "The browser could not open ChatGPT sign-in."
        case .listenerUnavailable: return "Capri could not start its local sign-in callback."
        case .invalidCallback: return "The ChatGPT sign-in response could not be verified."
        case .denied: return "ChatGPT sign-in was not approved."
        case .incompleteRegistration: return "ChatGPT did not complete this app's registration. Please try again."
        case .identityMismatch: return "The account returned by ChatGPT does not match this saved registration."
        case .invalidToken: return "The ChatGPT identity token could not be verified. Sign in again."
        case .malformedResponse: return "ChatGPT returned an incomplete authentication response."
        case .permissionMissing: return "Signed in, but ChatGPT plan use is not enabled for Capri. Continue with ChatGPT to review access."
        case .network: return "Could not reach ChatGPT authentication. Check your connection and try again."
        case .storage: return "Capri could not access its ChatGPT credentials in Keychain."
        case .server(let code):
            if Self.terminalRefreshErrors.contains(code) { return "Your ChatGPT session expired or was disconnected. Sign in again." }
            if code == "invalid_client" { return "ChatGPT rejected Capri's saved client registration. Add a new account registration." }
            return "ChatGPT authentication is temporarily unavailable. Please try again."
        }
    }

    static let terminalRefreshErrors: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused"
    ]
}

// Internal pure protocol helpers are also exercised by the offline test harness.
enum ChatGPTAuthProtocol {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let authorizationEndpoint = "https://auth.openai.com/api/accounts/authorize"
    static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let dynamicClient = "dynamic_agent_client"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              value.count % 4 != 1 else { throw ChatGPTAuthError.invalidToken }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw ChatGPTAuthError.invalidToken }
        return data
    }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTAuthError.invalidToken }
        return base64URL(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func form(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let string = parameters.keys.sorted().map {
            "\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(parameters[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(string.utf8)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    struct Callback: Sendable {
        let code: String
        let clientID: String
    }

    static func callback(target: String, state: String, clientID: String) throws -> Callback {
        guard target.hasPrefix("/auth/callback?"), target.utf8.count <= 16_384,
              let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/auth/callback", components.fragment == nil else { throw ChatGPTAuthError.invalidCallback }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { throw ChatGPTAuthError.invalidCallback }
            values[item.name] = value
        }
        guard let returnedState = values["state"], constantTimeEqual(returnedState, state) else { throw ChatGPTAuthError.invalidCallback }
        if values["error"] != nil { throw ChatGPTAuthError.denied }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 8192 else { throw ChatGPTAuthError.invalidCallback }
        let issued: String
        if clientID == dynamicClient {
            guard let value = values["client_id"], value.hasPrefix("oaiapp_"), value.count > 7, value.count < 512,
                  value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ChatGPTAuthError.incompleteRegistration }
            issued = value
        } else {
            if let returned = values["client_id"], returned != clientID { throw ChatGPTAuthError.identityMismatch }
            issued = clientID
        }
        return Callback(code: code, clientID: issued)
    }

    struct Identity: Sendable {
        let subject: String
        let email: String?
    }

    struct JWK: Decodable, Sendable {
        let kty: String
        let kid: String
        let use: String?
        let alg: String?
        let n: String?
        let e: String?
    }
    struct JWKS: Decodable, Sendable { let keys: [JWK] }

    static func tokenKeyID(_ token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count < 65_536,
              let header = try JSONSerialization.jsonObject(with: decodeBase64URL(String(parts[0]))) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String, !kid.isEmpty,
              header["crit"] == nil, header["b64"] == nil else { throw ChatGPTAuthError.invalidToken }
        return kid
    }

    static func der(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 { length.append(UInt8(content.count)) }
        else {
            var n = content.count
            var bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + content
    }

    static func rsaPublicKey(_ jwk: JWK) throws -> SecKey {
        guard jwk.kty == "RSA", jwk.use == nil || jwk.use == "sig", jwk.alg == nil || jwk.alg == "RS256",
              let n = jwk.n, let e = jwk.e else { throw ChatGPTAuthError.invalidToken }
        var modulus = try decodeBase64URL(n), exponent = try decodeBase64URL(e)
        guard (256...1024).contains(modulus.count), !exponent.isEmpty, exponent.count <= 8 else { throw ChatGPTAuthError.invalidToken }
        if modulus.first! & 0x80 != 0 { modulus.insert(0, at: 0) }
        if exponent.first! & 0x80 != 0 { exponent.insert(0, at: 0) }
        let encoded = der(0x30, der(0x02, modulus) + der(0x02, exponent))
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(encoded as CFData, options as CFDictionary, nil) else { throw ChatGPTAuthError.invalidToken }
        return key
    }

    static func validateIDToken(_ token: String, keys: JWKS, clientID: String, nonce: String?, subject: String?, now: Date = Date()) throws -> Identity {
        let kid = try tokenKeyID(token)
        let matches = keys.keys.filter { $0.kid == kid }
        guard matches.count == 1 else { throw ChatGPTAuthError.invalidToken }
        let key = try rsaPublicKey(matches[0])
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        let signature = try decodeBase64URL(String(parts[2]))
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil),
              let payload = try JSONSerialization.jsonObject(with: decodeBase64URL(String(parts[1]))) as? [String: Any] else { throw ChatGPTAuthError.invalidToken }
        func number(_ name: String) -> Double? {
            guard let value = payload[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        let audiences = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        let timestamp = now.timeIntervalSince1970
        guard payload["iss"] as? String == issuer, audiences.contains(clientID),
              let expiration = number("exp"), expiration > timestamp - 5,
              let issuedAt = number("iat"), issuedAt <= timestamp + 5, expiration > issuedAt,
              let verifiedSubject = payload["sub"] as? String, !verifiedSubject.isEmpty, verifiedSubject.count <= 1024 else { throw ChatGPTAuthError.invalidToken }
        if payload["nbf"] != nil { guard let nbf = number("nbf"), nbf <= timestamp + 5 else { throw ChatGPTAuthError.invalidToken } }
        if audiences.count > 1 || payload["azp"] != nil { guard payload["azp"] as? String == clientID else { throw ChatGPTAuthError.invalidToken } }
        if let nonce { guard let actual = payload["nonce"] as? String, constantTimeEqual(actual, nonce) else { throw ChatGPTAuthError.invalidToken } }
        if let subject, verifiedSubject != subject { throw ChatGPTAuthError.identityMismatch }
        return Identity(subject: verifiedSubject, email: payload["email"] as? String)
    }
}

private final class ChatGPTAuthRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class ChatGPTLoopback {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, any Error>?
    private var callback: CheckedContinuation<ChatGPTAuthProtocol.Callback, any Error>?
    private var result: Result<ChatGPTAuthProtocol.Callback, any Error>?
    private var timeout: Task<Void, Never>?
    private let state: String
    private let clientID: String
    private var port: UInt16 = 0

    init(state: String, clientID: String) { self.state = state; self.clientID = clientID }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw ChatGPTAuthError.listenerUnavailable }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port?.rawValue else { self.finish(.failure(ChatGPTAuthError.listenerUnavailable)); return }
                    self.port = port
                    self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port)/auth/callback")!)
                    self.ready = nil
                case .failed: self.finish(.failure(ChatGPTAuthError.listenerUnavailable))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)); self?.finish(.failure(ChatGPTAuthError.timedOut)) }
            catch { }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: .main)
        }
    }

    func waitForCallback() async throws -> ChatGPTAuthProtocol.Callback {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { callback = $0 }
    }

    func cancel() { finish(.failure(ChatGPTAuthError.cancelled)) }

    private func finish(_ result: Result<ChatGPTAuthProtocol.Callback, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let ready {
            switch result {
            case .failure(let error): ready.resume(throwing: error)
            case .success: ready.resume(throwing: ChatGPTAuthError.cancelled)
            }
            self.ready = nil
        }
        callback?.resume(with: result); callback = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, accumulated: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let connection = self?.connections.removeValue(forKey: id) else { return }
            connection.cancel()
        }
    }

    private func read(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let buffer = accumulated + (data ?? Data())
                guard buffer.count <= 16_384, error == nil else { self.reply(connection, id: id, accepted: false); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(buffer, connection: connection, id: id)
                } else if complete { self.reply(connection, id: id, accepted: false) }
                else { self.read(connection, id: id, accumulated: buffer) }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard let request = String(data: data, encoding: .utf8) else { reply(connection, id: id, accepted: false); return }
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else {
            reply(connection, id: id, accepted: false); return
        }
        do {
            let response = try ChatGPTAuthProtocol.callback(target: String(first[1]), state: state, clientID: clientID)
            reply(connection, id: id, accepted: true, outcome: .success(response))
        } catch ChatGPTAuthError.invalidCallback {
            // A random request cannot consume a pending authorization attempt.
            reply(connection, id: id, accepted: false)
        } catch {
            reply(connection, id: id, accepted: true, outcome: .failure(error))
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, accepted: Bool,
                       outcome: Result<ChatGPTAuthProtocol.Callback, any Error>? = nil) {
        let body = accepted ? "Capri received the ChatGPT sign-in response. You can return to Capri while it verifies your account." : "This is not a valid Capri sign-in callback."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.connections.removeValue(forKey: id)
                connection.cancel()
                if let outcome { self?.finish(outcome) }
            }
        })
    }
}

@MainActor
final class ChatGPTAuth {
    static let shared = ChatGPTAuth()

    struct AccountSummary: Identifiable {
        let id: String
        let label: String
        let isActive: Bool
        let isSignedIn: Bool
    }

    private struct Tokens: Codable, Sendable {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String
        var expiresAt: Date
        var earliestRefreshAt: Date?
        var scopes: [String]
    }
    private struct Registration: Codable, Sendable {
        let clientID: String
        let subject: String
        var email: String?
        var tokens: Tokens?
    }
    private struct Vault: Codable {
        var hostID: String
        var activeClientID: String?
        var registrations: [Registration]
    }
    private struct Discovery: Decodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let jwks_uri: String
        let revocation_endpoint: String
    }
    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let id_token: String?
        let token_type: String?
        let expires_in: Double?
        let scope: String?
        let earliest_refresh_at: Double?
    }
    private struct OAuthFailure: Decodable { let error: String? }

    private let service = "local.capri.maccompanion.chatgpt"
    private let keychainAccount = "oauth-v1"
    private var vault: Vault
    private var storageFailed = false
    private var generation = UUID()
    private var signInTask: Task<Void, any Error>?
    private var refreshTask: Task<Tokens, any Error>?
    private var callbackListener: ChatGPTLoopback?
    private var keys: (ChatGPTAuthProtocol.JWKS, Date)?
    private let session: URLSession
    private(set) var statusDescription = "Not connected to ChatGPT"
    var isSignedIn: Bool { activeRegistration?.tokens != nil }
    var isSigningIn: Bool { signInTask != nil }
    var hasPlanAccess: Bool { activeRegistration?.tokens?.scopes.contains("chatgpt.tokens.use.direct") == true }
    var accounts: [AccountSummary] {
        vault.registrations.map { AccountSummary(id: $0.clientID,
            label: "\($0.email ?? "ChatGPT account") · \($0.clientID.suffix(6))",
            isActive: $0.clientID == vault.activeClientID, isSignedIn: $0.tokens != nil) }
    }
    private var activeRegistration: Registration? { vault.registrations.first { $0.clientID == vault.activeClientID } }

    private init() {
        vault = Vault(hostID: "urn:uuid:\(UUID().uuidString.lowercased())", activeClientID: nil, registrations: [])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: ChatGPTAuthRedirectBlocker(), delegateQueue: nil)
        do {
            if let data = try readKeychain() { vault = try JSONDecoder().decode(Vault.self, from: data) }
            updateStatus()
        } catch { storageFailed = true; statusDescription = ChatGPTAuthError.storage.localizedDescription }
    }

    /// Connects the selected saved registration, or dynamically registers a new
    /// one when requested. No browser or permission request happens at startup.
    func signIn(addAccount: Bool = false) async throws {
        guard signInTask == nil else { throw ChatGPTAuthError.busy }
        if storageFailed {
            do {
                if let data = try readKeychain(allowInteraction: true) { vault = try JSONDecoder().decode(Vault.self, from: data) }
                storageFailed = false
            } catch { throw ChatGPTAuthError.storage }
        }
        refreshTask?.cancel(); refreshTask = nil
        generation = UUID(); let operation = generation
        let selected = addAccount ? nil : activeRegistration
        try saveVault(vault) // Persist the host ID before first authorization.
        statusDescription = "Waiting for ChatGPT sign-in…"
        let task = Task { try await self.performSignIn(selected: selected, operation: operation) }
        signInTask = task
        defer { if generation == operation { signInTask = nil; callbackListener = nil } }
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
        } catch {
            if generation == operation {
                callbackListener?.cancel()
                statusDescription = error is CancellationError ? ChatGPTAuthError.cancelled.localizedDescription : safeDescription(error)
            }
            throw error
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        callbackListener?.cancel()
    }

    func selectAccount(clientID: String) throws {
        guard vault.registrations.contains(where: { $0.clientID == clientID }) else { throw ChatGPTAuthError.signedOut }
        invalidateOperations()
        var updated = vault; updated.activeClientID = clientID
        try saveVault(updated); updateStatus()
    }

    /// Clears local tokens immediately, retaining the verified account/client
    /// mapping and stable host ID. Revocation is attempted in the background;
    /// statusDescription reports if remote revocation could not be confirmed.
    func signOut() throws {
        let registration = activeRegistration
        invalidateOperations()
        var updated = vault
        if let index = updated.registrations.firstIndex(where: { $0.clientID == updated.activeClientID }) { updated.registrations[index].tokens = nil }
        try saveVault(updated)
        guard let registration, let token = registration.tokens?.refreshToken else { updateStatus(); return }
        statusDescription = "Signed out locally. Ending the ChatGPT session…"
        let operation = generation
        Task { [weak self] in
            guard let self else { return }
            var revoked = false
            for attempt in 0..<2 {
                do { try await self.revoke(token: token, clientID: registration.clientID); revoked = true; break }
                catch { if attempt == 0 { try? await Task.sleep(for: .seconds(1)) } }
            }
            guard self.generation == operation else { return }
            self.statusDescription = revoked ? "Signed out of ChatGPT" : "Signed out locally. Remote revocation was not confirmed; disconnect Capri in ChatGPT Settings if needed."
        }
    }

    func validAccessToken() async throws -> String {
        try Task.checkCancellation()
        guard let registration = activeRegistration, let current = registration.tokens else { throw ChatGPTAuthError.signedOut }
        let operation = generation
        guard current.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTAuthError.permissionMissing }
        if let token = current.accessToken, !token.isEmpty, current.expiresAt.timeIntervalSinceNow > 60 { return token }
        if let earliest = current.earliestRefreshAt, earliest > Date(), current.expiresAt > Date(), let token = current.accessToken { return token }
        if let refreshTask {
            let refreshed = try await refreshTask.value
            try check(operation)
            guard let token = refreshed.accessToken else { throw ChatGPTAuthError.signedOut }
            return token
        }
        guard current.refreshToken != nil else { throw ChatGPTAuthError.signedOut }
        let task = Task { try await self.refresh(registration, operation: operation) }
        refreshTask = task
        defer { if generation == operation { refreshTask = nil } }
        let refreshed = try await task.value
        try check(operation)
        guard let token = refreshed.accessToken else { throw ChatGPTAuthError.signedOut }
        return token
    }

    private func performSignIn(selected: Registration?, operation: UUID) async throws {
        let discovery = try await discover()
        var clientID = selected?.clientID ?? ChatGPTAuthProtocol.dynamicClient
        for attempt in 0..<2 {
            try check(operation)
            let state = try ChatGPTAuthProtocol.randomValue(), nonce = try ChatGPTAuthProtocol.randomValue(), verifier = try ChatGPTAuthProtocol.randomValue()
            let listener = ChatGPTLoopback(state: state, clientID: clientID)
            callbackListener = listener
            let callback: ChatGPTAuthProtocol.Callback
            let redirect: URL
            do {
                redirect = try await withTaskCancellationHandler(operation: { try await listener.start() }, onCancel: { Task { @MainActor in listener.cancel() } })
                try check(operation)
                var components = URLComponents(string: discovery.authorization_endpoint)!
                var parameters = ["client_id": clientID, "ext_agent_host_id": vault.hostID,
                    "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": ChatGPTAuthProtocol.scopes,
                    "resource": ChatGPTAuthProtocol.resource, "state": state, "nonce": nonce,
                    "code_challenge_method": "S256", "code_challenge": ChatGPTAuthProtocol.challenge(verifier)]
                if clientID == ChatGPTAuthProtocol.dynamicClient { parameters["agent_name_hint"] = "Capri for Mac" }
                else if let selected {
                    parameters["id_token_hint"] = selected.tokens?.idToken
                    parameters["login_hint"] = selected.email
                }
                components.queryItems = parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
                guard let url = components.url, NSWorkspace.shared.open(url) else { throw ChatGPTAuthError.browserUnavailable }
                callback = try await withTaskCancellationHandler(operation: { try await listener.waitForCallback() }, onCancel: { Task { @MainActor in listener.cancel() } })
            } catch { listener.cancel(); throw error }
            clientID = callback.clientID
            let response: TokenResponse
            do {
                response = try await tokenRequest(["grant_type": "authorization_code", "client_id": clientID,
                    "code": callback.code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "resource": ChatGPTAuthProtocol.resource])
            } catch ChatGPTAuthError.server("invalid_grant") where attempt == 0 {
                // A consumed/expired code is never reused. The next attempt uses
                // the just-issued client ID and new PKCE/state/nonce values.
                continue
            }
            guard let idToken = response.id_token else { throw ChatGPTAuthError.malformedResponse }
            let identity = try await validate(idToken, clientID: clientID, nonce: nonce, subject: selected?.subject, discovery: discovery)
            let tokens = try makeTokens(response, previous: nil)
            try check(operation)
            var updated = vault
            if let index = updated.registrations.firstIndex(where: { $0.clientID == clientID }) {
                guard updated.registrations[index].subject == identity.subject else { throw ChatGPTAuthError.identityMismatch }
                updated.registrations[index].email = identity.email
                updated.registrations[index].tokens = tokens
            } else { updated.registrations.append(Registration(clientID: clientID, subject: identity.subject, email: identity.email, tokens: tokens)) }
            updated.activeClientID = clientID
            try saveVault(updated); updateStatus()
            return
        }
        throw ChatGPTAuthError.incompleteRegistration
    }

    private func refresh(_ registration: Registration, operation: UUID) async throws -> Tokens {
        guard let previous = registration.tokens, let refreshToken = previous.refreshToken else { throw ChatGPTAuthError.signedOut }
        do {
            let response = try await tokenRequest(["grant_type": "refresh_token", "client_id": registration.clientID,
                "refresh_token": refreshToken, "resource": ChatGPTAuthProtocol.resource])
            if let idToken = response.id_token {
                let discovery = try await discover()
                _ = try await validate(idToken, clientID: registration.clientID, nonce: nil, subject: registration.subject, discovery: discovery)
            }
            let tokens = try makeTokens(response, previous: previous)
            try check(operation)
            var updated = vault
            guard let index = updated.registrations.firstIndex(where: { $0.clientID == registration.clientID && $0.subject == registration.subject }) else { throw ChatGPTAuthError.signedOut }
            updated.registrations[index].tokens = tokens
            try saveVault(updated); updateStatus()
            guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTAuthError.permissionMissing }
            return tokens
        } catch ChatGPTAuthError.server(let code) where ChatGPTAuthError.terminalRefreshErrors.contains(code) {
            try check(operation)
            var updated = vault
            if let index = updated.registrations.firstIndex(where: { $0.clientID == registration.clientID }) { updated.registrations[index].tokens = nil }
            try saveVault(updated); updateStatus()
            throw ChatGPTAuthError.server(code)
        }
    }

    private func makeTokens(_ response: TokenResponse, previous: Tokens?) throws -> Tokens {
        guard let idToken = response.id_token ?? previous?.idToken,
              let scope = response.scope ?? previous?.scopes.joined(separator: " ") else { throw ChatGPTAuthError.malformedResponse }
        let scopes = scope.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if response.access_token != nil {
            guard response.token_type?.lowercased() == "bearer", let lifetime = response.expires_in,
                  lifetime.isFinite, lifetime > 0 else { throw ChatGPTAuthError.malformedResponse }
        }
        if scopes.contains("chatgpt.tokens.use.direct") {
            guard let access = response.access_token, !access.isEmpty else { throw ChatGPTAuthError.malformedResponse }
        }
        // Refresh-token rotation is atomic with access token and expiry. Do not
        // reuse a previous refresh token after a successful refresh response.
        if previous != nil, response.refresh_token == nil { throw ChatGPTAuthError.malformedResponse }
        return Tokens(accessToken: response.access_token, refreshToken: response.refresh_token,
            idToken: idToken, expiresAt: Date().addingTimeInterval(min(response.expires_in ?? 0, 3600)),
            earliestRefreshAt: response.earliest_refresh_at.map(Date.init(timeIntervalSince1970:)), scopes: scopes)
    }

    private func validate(_ token: String, clientID: String, nonce: String?, subject: String?, discovery: Discovery) async throws -> ChatGPTAuthProtocol.Identity {
        let kid = try ChatGPTAuthProtocol.tokenKeyID(token)
        if keys == nil || keys!.1.timeIntervalSinceNow < -600 || !keys!.0.keys.contains(where: { $0.kid == kid }) {
            let (data, _) = try await request(URLRequest(url: URL(string: discovery.jwks_uri)!))
            guard let parsed = try? JSONDecoder().decode(ChatGPTAuthProtocol.JWKS.self, from: data) else { throw ChatGPTAuthError.invalidToken }
            keys = (parsed, Date())
        }
        return try ChatGPTAuthProtocol.validateIDToken(token, keys: keys!.0, clientID: clientID, nonce: nonce, subject: subject)
    }

    private func discover() async throws -> Discovery {
        let (data, _) = try await request(URLRequest(url: URL(string: ChatGPTAuthProtocol.issuer + "/.well-known/openid-configuration")!))
        guard let metadata = try? JSONDecoder().decode(Discovery.self, from: data), metadata.issuer == ChatGPTAuthProtocol.issuer,
              metadata.authorization_endpoint == ChatGPTAuthProtocol.authorizationEndpoint,
              metadata.token_endpoint == ChatGPTAuthProtocol.tokenEndpoint,
              metadata.jwks_uri == ChatGPTAuthProtocol.issuer + "/.well-known/jwks.json",
              metadata.revocation_endpoint == ChatGPTAuthProtocol.issuer + "/api/accounts/oauth/revoke" else { throw ChatGPTAuthError.malformedResponse }
        return metadata
    }

    private func tokenRequest(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: ChatGPTAuthProtocol.tokenEndpoint)!)
        request.httpMethod = "POST"; request.httpBody = ChatGPTAuthProtocol.form(parameters)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await self.request(request)
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw ChatGPTAuthError.malformedResponse }
        return response
    }

    private func revoke(token: String, clientID: String) async throws {
        let metadata = try await discover()
        var request = URLRequest(url: URL(string: metadata.revocation_endpoint)!)
        request.httpMethod = "POST"; request.httpBody = ChatGPTAuthProtocol.form(["token": token, "token_type_hint": "refresh_token", "client_id": clientID])
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        _ = try await self.request(request)
    }

    private func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https", request.url?.host == "auth.openai.com", request.url?.user == nil,
              request.url?.password == nil, request.url?.port == nil else { throw ChatGPTAuthError.network }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw ChatGPTAuthError.network }
        guard let http = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else { throw ChatGPTAuthError.malformedResponse }
        guard http.statusCode == 200 else {
            let allowed = ChatGPTAuthError.terminalRefreshErrors.union(["invalid_client", "temporarily_unavailable", "access_denied"])
            let error = (try? JSONDecoder().decode(OAuthFailure.self, from: data))?.error
            throw ChatGPTAuthError.server(error.flatMap { allowed.contains($0) ? $0 : nil } ?? "unavailable")
        }
        return (data, http)
    }

    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operation == generation else { throw ChatGPTAuthError.cancelled }
    }

    private func invalidateOperations() {
        generation = UUID()
        signInTask?.cancel(); signInTask = nil
        refreshTask?.cancel(); refreshTask = nil
        callbackListener?.cancel(); callbackListener = nil
    }

    private func updateStatus() {
        guard let registration = activeRegistration, registration.tokens != nil else { statusDescription = "Not connected to ChatGPT"; return }
        statusDescription = hasPlanAccess ? "Connected to ChatGPT\(registration.email.map { " · " + $0 } ?? "")" : ChatGPTAuthError.permissionMissing.localizedDescription
    }

    private func safeDescription(_ error: any Error) -> String {
        (error as? ChatGPTAuthError)?.localizedDescription ?? ChatGPTAuthError.network.localizedDescription
    }

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: keychainAccount, kSecAttrSynchronizable as String: false]
    }

    private func readKeychain(allowInteraction: Bool = false) throws -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ChatGPTAuthError.storage }
        return data
    }

    private func saveVault(_ value: Vault) throws {
        let data = try JSONEncoder().encode(value)
        let query = keychainQuery()
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ChatGPTAuthError.storage }
        vault = value
    }
}

import Foundation
import Security

// Offline only: generated RSA key, synthetic claims, and loopback HTTP requests.
// Never instantiate ChatGPTAuth.shared, read Keychain, or open a browser.
@main
struct ChatGPTAuthTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw NSError(domain: "AuthTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks += 1
    }
    @MainActor static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NSError(domain: "AuthTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Accepted invalid input: " + label])
    }
    static func readDER(_ data: Data, _ cursor: inout Int, tag: UInt8) throws -> Data {
        let bytes = [UInt8](data)
        guard cursor + 2 <= bytes.count, bytes[cursor] == tag else { throw ChatGPTAuthError.invalidToken }
        cursor += 1
        var length = Int(bytes[cursor]); cursor += 1
        if length & 128 != 0 {
            let count = length & 127; length = 0
            guard count > 0, count < 5, cursor + count <= bytes.count else { throw ChatGPTAuthError.invalidToken }
            for _ in 0..<count { length = (length << 8) | Int(bytes[cursor]); cursor += 1 }
        }
        guard cursor + length <= bytes.count else { throw ChatGPTAuthError.invalidToken }
        let result = Data(bytes[cursor..<cursor + length]); cursor += length
        return result
    }
    static func jwks(_ key: SecKey) throws -> ChatGPTAuthProtocol.JWKS {
        let publicKey = SecKeyCopyPublicKey(key)!
        let data = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var index = 0
        let sequence = try readDER(data, &index, tag: 0x30)
        index = 0
        var n = try readDER(sequence, &index, tag: 0x02)
        var e = try readDER(sequence, &index, tag: 0x02)
        while n.first == 0 { n.removeFirst() }; while e.first == 0 { e.removeFirst() }
        let json: [String: Any] = ["keys": [["kty": "RSA", "kid": "synthetic", "alg": "RS256", "use": "sig", "n": ChatGPTAuthProtocol.base64URL(n), "e": ChatGPTAuthProtocol.base64URL(e)]]]
        return try JSONDecoder().decode(ChatGPTAuthProtocol.JWKS.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func token(_ key: SecKey, claims: [String: Any], header: [String: Any] = ["alg": "RS256", "kid": "synthetic"]) throws -> String {
        let a = ChatGPTAuthProtocol.base64URL(try JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
        let b = ChatGPTAuthProtocol.base64URL(try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let input = Data("\(a).\(b)".utf8)
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
        return "\(a).\(b).\(ChatGPTAuthProtocol.base64URL(signature))"
    }

    @MainActor static func main() async throws {
        try check(ChatGPTAuthProtocol.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 PKCE vector")
        let randomA = try ChatGPTAuthProtocol.randomValue(), randomB = try ChatGPTAuthProtocol.randomValue()
        try check(randomA.count == 43 && randomA != randomB, "Fresh cryptographic randomness")
        try check(String(data: ChatGPTAuthProtocol.form(["a": "x+y&z=/: ?"]), encoding: .utf8) == "a=x%2By%26z%3D%2F%3A%20%3F", "Form encoding injection")
        let callback = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=nonce&code=synthetic%2Bcode&client_id=oaiapp_test", state: "nonce", clientID: "dynamic_agent_client")
        try check(callback.clientID == "oaiapp_test" && callback.code == "synthetic+code", "Dynamic issued ID and code parsing")
        try rejects("state mismatch") { _ = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=bad&code=x&client_id=oaiapp_test", state: "nonce", clientID: "dynamic_agent_client") }
        try rejects("duplicate state") { _ = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=nonce&state=nonce&code=x&client_id=oaiapp_test", state: "nonce", clientID: "dynamic_agent_client") }
        try rejects("missing issued ID") { _ = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=nonce&code=x", state: "nonce", clientID: "dynamic_agent_client") }
        try rejects("changed registration") { _ = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=nonce&code=x&client_id=oaiapp_other", state: "nonce", clientID: "oaiapp_test") }
        try rejects("OAuth denial") { _ = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=nonce&error=access_denied", state: "nonce", clientID: "oaiapp_test") }
        try rejects("wrong callback path") { _ = try ChatGPTAuthProtocol.callback(target: "/callback?state=nonce&code=x", state: "nonce", clientID: "oaiapp_test") }
        let returning = try ChatGPTAuthProtocol.callback(target: "/auth/callback?state=nonce&code=x", state: "nonce", clientID: "oaiapp_test")
        try check(returning.clientID == "oaiapp_test", "Returning callback retains issued ID")

        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let keys = try jwks(key)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let base: [String: Any] = ["iss": "https://auth.openai.com", "sub": "synthetic-subject", "aud": "oaiapp_test", "iat": now.timeIntervalSince1970 - 10, "exp": now.timeIntervalSince1970 + 3600, "nonce": "synthetic-nonce", "email": "synthetic@example.invalid"]
        func validate(_ claims: [String: Any], header: [String: Any] = ["alg": "RS256", "kid": "synthetic"]) throws -> ChatGPTAuthProtocol.Identity {
            try ChatGPTAuthProtocol.validateIDToken(token(key, claims: claims, header: header), keys: keys, clientID: "oaiapp_test", nonce: "synthetic-nonce", subject: nil, now: now)
        }
        let identity = try validate(base)
        try check(identity.subject == "synthetic-subject", "RSA signature and valid claims")
        for (field, value) in [("iss", "https://attacker.invalid" as Any), ("aud", "oaiapp_other" as Any), ("exp", now.timeIntervalSince1970 - 60 as Any), ("iat", now.timeIntervalSince1970 + 60 as Any), ("nonce", "incorrect" as Any), ("sub", "" as Any), ("exp", true as Any), ("nbf", now.timeIntervalSince1970 + 60 as Any)] {
            var altered = base; altered[field] = value
            try rejects("claim " + field) { _ = try validate(altered) }
        }
        try rejects("algorithm confusion") { _ = try validate(base, header: ["alg": "HS256", "kid": "synthetic"]) }
        try rejects("unknown key") { _ = try validate(base, header: ["alg": "RS256", "kid": "unknown"]) }
        try rejects("unknown critical header") { _ = try validate(base, header: ["alg": "RS256", "kid": "synthetic", "crit": ["custom"]]) }
        var multiple = base; multiple["aud"] = ["oaiapp_test", "another"]
        try rejects("multiple audiences without authorized party") { _ = try validate(multiple) }
        multiple["azp"] = "oaiapp_test"
        _ = try validate(multiple); checks += 1
        let signed = try token(key, claims: base)
        var parts = signed.split(separator: ".").map(String.init)
        var signature = try ChatGPTAuthProtocol.decodeBase64URL(parts[2]); signature[0] ^= 1
        parts[2] = ChatGPTAuthProtocol.base64URL(signature)
        try rejects("tampered signature") { _ = try ChatGPTAuthProtocol.validateIDToken(parts.joined(separator: "."), keys: keys, clientID: "oaiapp_test", nonce: "synthetic-nonce", subject: nil, now: now) }
        try rejects("returning identity mismatch") { _ = try ChatGPTAuthProtocol.validateIDToken(signed, keys: keys, clientID: "oaiapp_test", nonce: "synthetic-nonce", subject: "other-account", now: now) }
        try rejects("unsigned token") { _ = try ChatGPTAuthProtocol.tokenKeyID("e30.e30.") }

        // Exercise the actual local listener without opening a browser.
        let listener = ChatGPTLoopback(state: "synthetic-state", clientID: "dynamic_agent_client")
        let redirect = try await listener.start()
        try check(redirect.host == "127.0.0.1" && redirect.path == "/auth/callback" && redirect.port != nil, "Loopback callback address")
        var wrong = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        wrong.queryItems = [URLQueryItem(name: "state", value: "wrong"), URLQueryItem(name: "code", value: "synthetic")]
        let (_, invalidResponse) = try await URLSession.shared.data(from: wrong.url!)
        try check((invalidResponse as? HTTPURLResponse)?.statusCode == 400, "Invalid state does not consume attempt")
        var correct = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        correct.queryItems = [URLQueryItem(name: "state", value: "synthetic-state"), URLQueryItem(name: "code", value: "synthetic"), URLQueryItem(name: "client_id", value: "oaiapp_synthetic")]
        let (_, validResponse) = try await URLSession.shared.data(from: correct.url!)
        try check((validResponse as? HTTPURLResponse)?.statusCode == 200, "Valid callback accepted")
        let result = try await listener.waitForCallback()
        try check(result.clientID == "oaiapp_synthetic", "Listener returns issued registration")
        let cancelled = ChatGPTLoopback(state: "synthetic-state", clientID: "oaiapp_synthetic")
        _ = try await cancelled.start(); cancelled.cancel()
        do { _ = try await cancelled.waitForCallback(); throw NSError(domain: "AuthTest", code: 3) }
        catch ChatGPTAuthError.cancelled { checks += 1 }
        print("ChatGPT auth: \(checks) offline checks passed. No Keychain access or external authentication requests.")
    }
}

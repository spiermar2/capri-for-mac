import Foundation

// Every request from the tested ChatGPT session is intercepted here. These
// fixtures never instantiate ChatGPTAuth.shared or read the user's Keychain.
private final class OfflineRequests: @unchecked Sendable {
    enum Mode { case success, modelUnavailable, unauthorizedReply }
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var mode = Mode.success

    func reset(_ mode: Mode = .success) {
        lock.lock(); defer { lock.unlock() }
        requests = []; self.mode = mode
    }

    func snapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func response(for request: URLRequest) -> (Int, String, Data) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        guard request.url?.scheme == "https", request.url?.host == "api.openai.com" else {
            return (500, "application/json", Data("{}".utf8))
        }
        if request.url?.path == "/v1/models" {
            let slug = mode == .modelUnavailable ? "another-model" : "gpt-6.1-sol"
            let body = "{\"models\":[{\"slug\":\"\(slug)\",\"display_name\":\"Synthetic model\",\"visibility\":\"list\"}]}"
            return (200, "application/json", Data(body.utf8))
        }
        guard request.url?.path == "/v1/responses", request.httpMethod == "POST" else {
            return (500, "application/json", Data("{}".utf8))
        }
        if mode == .unauthorizedReply {
            return (401, "application/json", Data("{\"error\":{\"code\":\"invalid_authorization\"}}".utf8))
        }
        let event = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Offline fixture reply\"}]}]}}\n\n"
        return (200, "text/event-stream", Data(event.utf8))
    }
}

private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = OfflineRequests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, contentType, data) = Self.recorder.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
private final class SyntheticAccount {
    var token = "synthetic-account-a-token"
    private(set) var credentialReads = 0
    func credential() -> String { credentialReads += 1; return token }
}

@main
struct CredentialIsolationTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
            FileHandle.standardOutput.write(Data("PASS \(label)\n".utf8))
        }
        let recorder = OfflineURLProtocol.recorder
        let messages = [["role": "user", "content": "Synthetic test message"]]

        // Both model discovery and inference must stop before the transport
        // when the selected local account supplies no usable credential.
        let denied: [(String, @MainActor () async throws -> String)] = [
            ("signed out", { throw ChatGPTAuthError.signedOut }),
            ("plan permission missing", { throw ChatGPTAuthError.permissionMissing }),
            ("empty token", { "" }),
            ("whitespace token", { " " }),
            ("header injection token", { "synthetic\r\nX-Injected: rejected" }),
            ("non-ASCII token", { "synthetic-🛑" })
        ]
        for (label, provider) in denied {
            recorder.reset()
            let client = ChatGPTClient(tokenProvider: provider, protocolClasses: [OfflineURLProtocol.self])
            do { _ = try await client.availableModels(); preconditionFailure("Accepted \(label)") }
            catch { expect(recorder.snapshot().isEmpty, "\(label) blocks model discovery before transport") }
            do {
                _ = try await client.reply(instructions: "Synthetic instructions", messages: messages, model: "gpt-6.1-sol")
                preconditionFailure("Accepted \(label)")
            } catch { expect(recorder.snapshot().isEmpty, "\(label) blocks inference before transport") }
        }

        // Reuse one client while the selected account changes. Each reply
        // obtains exactly one fresh token; its catalog and inference share it.
        recorder.reset()
        let account = SyntheticAccount()
        let client = ChatGPTClient(tokenProvider: {
            account.credential()
        }, protocolClasses: [OfflineURLProtocol.self])
        for token in ["synthetic-account-a-token", "synthetic-account-b-token"] {
            account.token = token
            let reply = try await client.reply(instructions: "Synthetic instructions", messages: messages, model: "gpt-6.1-sol")
            expect(reply == "Offline fixture reply", "synthetic account completes only an intercepted reply")
        }
        let requests = recorder.snapshot()
        expect(account.credentialReads == 2 && requests.count == 4, "each account gets one catalog check and one inference without retries")
        expect(requests.map { $0.url?.path } == ["/v1/models", "/v1/responses", "/v1/models", "/v1/responses"],
               "both accounts use only the fixed model and Responses endpoints")
        expect(requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-account-a-token" },
               "first account supplies its own bearer to catalog and inference")
        expect(requests.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-account-b-token" },
               "second account replaces the bearer without reusing the first account")
        expect(requests.allSatisfy {
            $0.url?.scheme == "https" && $0.url?.host == "api.openai.com" &&
            $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "xi-api-key") == nil
        }, "ChatGPT requests contain no cross-provider key or cookie")
        expect(requests.allSatisfy {
            let body = String(data: $0.httpBody ?? Data(), encoding: .utf8) ?? ""
            let address = $0.url?.absoluteString ?? ""
            return !body.contains("synthetic-account-") && !address.contains("synthetic-account-")
        }, "ChatGPT credentials stay out of URL and request body")

        recorder.reset(.modelUnavailable)
        do {
            _ = try await client.reply(instructions: "Synthetic instructions", messages: messages, model: "gpt-6.1-sol")
            preconditionFailure("Unavailable model must fail")
        } catch {
            expect(recorder.snapshot().count == 1, "missing model entitlement stops before inference without fallback")
        }
        recorder.reset(.unauthorizedReply)
        do {
            _ = try await client.reply(instructions: "Synthetic instructions", messages: messages, model: "gpt-6.1-sol")
            preconditionFailure("Unauthorized account must fail")
        } catch {
            let failed = recorder.snapshot()
            expect(failed.count == 2, "rejected authorization has no inference retry or alternate billing request")
            expect(failed.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-account-b-token" },
                   "authorization failure never falls back to the previous account")
        }

        // Pure request construction: no ElevenLabsVoice instance, Keychain,
        // microphone, network, or audio playback is involved.
        let invalidVoiceKeys: [String?] = [nil, "", " ", "synthetic key", "synthetic\n", "synthetic\r\nX-Test: value", "synthetic\0", "synthetic-🛑", String(repeating: "x", count: 4097)]
        for (index, key) in invalidVoiceKeys.enumerated() {
            do {
                _ = try ElevenLabsVoice.makeRequest(text: "Synthetic speech", voiceID: "synthetic-voice", key: key)
                preconditionFailure("Accepted invalid voice credential \(index)")
            } catch { expect(true, "invalid voice credential case \(index) fails before request creation") }
        }
        let voiceA = try ElevenLabsVoice.makeRequest(text: "Synthetic speech", voiceID: "synthetic-voice", key: "synthetic-voice-key-a")
        let voiceB = try ElevenLabsVoice.makeRequest(text: "Synthetic speech", voiceID: "synthetic-voice", key: "synthetic-voice-key-b")
        expect(voiceA.value(forHTTPHeaderField: "xi-api-key") == "synthetic-voice-key-a" &&
               voiceB.value(forHTTPHeaderField: "xi-api-key") == "synthetic-voice-key-b", "each ElevenLabs request uses only its supplied account key")
        expect([voiceA, voiceB].allSatisfy {
            $0.url?.scheme == "https" && $0.url?.host == "api.elevenlabs.io" &&
            $0.url?.path == "/v1/text-to-speech/synthetic-voice/stream" &&
            $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil
        }, "voice credentials use only the fixed ElevenLabs endpoint without ChatGPT authorization")
        expect([voiceA, voiceB].allSatisfy {
            let body = String(data: $0.httpBody ?? Data(), encoding: .utf8) ?? ""
            return !body.contains("synthetic-voice-key-") && !($0.url?.absoluteString ?? "").contains("synthetic-voice-key-")
        }, "voice credentials stay out of URL and request body")
        let bodyA = try JSONSerialization.jsonObject(with: voiceA.httpBody!) as! NSDictionary
        let bodyB = try JSONSerialization.jsonObject(with: voiceB.httpBody!) as! NSDictionary
        expect(bodyA.isEqual(bodyB), "changing voice accounts cannot inject credentials into speech text")
        print("\(checks) credential-isolation checks passed; transport intercepted; no Keychain or external network access")
    }
}

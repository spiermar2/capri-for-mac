import Foundation
@preconcurrency import AVFoundation
import Security
import LocalAuthentication

/// Capri's original ElevenLabs voice. This service never substitutes a Mac
/// voice. Creating it, checking hasAPIKey, and saving a key do not make requests.
@MainActor
final class ElevenLabsVoice: NSObject {
    static let originalVoiceID = "MkTSSXNgnBULS6ek4pon"

    var voiceID = ElevenLabsVoice.originalVoiceID {
        didSet { if oldValue != voiceID { stop() } }
    }
    var onSpeakingChange: ((Bool) -> Void)?
    var onPreparingChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isSpeaking = false
    private(set) var isPreparing = false

    private static let keychainService = "local.capri.maccompanion.elevenlabs"
    private static let keychainAccount = "api-key"
    private let network = ElevenLabsVoice.makeNetworkSession()
    private var generationTask: Task<Void, Never>?
    private var generation = UUID()
    private var player: PCMStreamPlayer?

    /// Queries item attributes only. The secret never enters UI state.
    var hasAPIKey: Bool {
        var query = Self.keychainQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func saveAPIKey(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw VoiceFailure("Paste a valid ElevenLabs API key without spaces or line breaks.")
        }
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(Self.keychainQuery as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = Self.keychainQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Capri — ElevenLabs API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw Self.keychainFailure("save", status: status)
        }
        stop()
    }

    func forgetAPIKey() throws {
        stop()
        let status = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.keychainFailure("remove", status: status)
        }
    }

    /// Sends only the requested words to ElevenLabs. Call only when the user has
    /// enabled cloud voice; this method does not initiate microphone access.
    func speak(_ text: String) {
        stop()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        guard words.count <= 10_000 else {
            onError?("This reply is too long for one Capri voice request. The full reply remains in chat.")
            return
        }
        let request: URLRequest
        do {
            request = try Self.makeRequest(text: words, voiceID: voiceID, key: loadAPIKey())
        } catch {
            onError?(error.localizedDescription)
            return
        }
        let token = generation
        setPreparing(true)
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await self.network.bytes(for: request)
                defer { bytes.task.cancel() }
                try self.checkCurrent(token)
                guard let response = response as? HTTPURLResponse else {
                    throw PCMStreamFailure.invalidResponse
                }
                guard response.url?.scheme == "https", response.url?.host == "api.elevenlabs.io" else {
                    throw PCMStreamFailure.unexpectedAddress
                }
                guard (200...299).contains(response.statusCode) else {
                    var body = Data()
                    // Error responses never enter the PCM decoder or player.
                    // Stop reading at a fixed cap rather than buffering a body.
                    for try await byte in bytes {
                        try self.checkCurrent(token)
                        body.append(byte)
                        if body.count == 65_536 { break }
                    }
                    throw VoiceFailure(Self.serviceError(status: response.statusCode, body: body))
                }
                var decoder = try PCMStreamDecoder(response: response)
                let player = try PCMStreamPlayer(onPlaybackChange: { [weak self] playing in
                    guard let self, self.generation == token else { return }
                    self.setPreparing(!playing && self.generationTask != nil)
                    self.setSpeaking(playing)
                }, onCompletion: { [weak self] in
                    self?.playbackFinished(token: token)
                })
                self.player = player
                for try await byte in bytes {
                    try self.checkCurrent(token)
                    if let samples = try decoder.append(byte) {
                        try await self.schedule(samples, player: player, networkTask: bytes.task, token: token)
                    }
                }
                try self.checkCurrent(token)
                if let samples = try decoder.finish() {
                    try await self.schedule(samples, player: player, networkTask: bytes.task, token: token)
                }
                self.generationTask = nil
                self.setPreparing(false)
                // The last audio is still queued: speaking ends only after
                // AVFoundation reports that the device played the last buffer.
                player.finishInput()
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.generationTask = nil
                let previous = self.player
                self.player = nil
                previous?.stop()
                self.setPreparing(false)
                self.setSpeaking(false)
                if let failure = error as? VoiceFailure {
                    self.onError?(failure.localizedDescription)
                } else if let failure = error as? PCMStreamFailure {
                    self.onError?(Self.streamError(failure))
                } else if let networkError = error as? URLError {
                    if networkError.code != .cancelled {
                        self.onError?("The ElevenLabs voice connection was interrupted. Check your internet and try again; the full reply remains in chat.")
                    }
                } else {
                    self.onError?("Capri's audio could not play on this Mac. Please try again; the reply remains in chat.")
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        generationTask?.cancel()
        generationTask = nil
        let previous = player
        player = nil
        previous?.stop()
        setPreparing(false)
        setSpeaking(false)
    }

    private func schedule(_ samples: [Float], player: PCMStreamPlayer, networkTask: URLSessionTask, token: UUID) async throws {
        // Backpressure bounds scheduled PCM to two seconds. Waiting yields the
        // main actor, so the UI and actual-playback completions remain responsive.
        let needsBackpressure = !player.canAccept(frameCount: samples.count)
        if needsBackpressure { networkTask.suspend() }
        defer { if needsBackpressure { networkTask.resume() } }
        while !player.canAccept(frameCount: samples.count) {
            try checkCurrent(token)
            guard !player.isStopped else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(12))
        }
        try checkCurrent(token)
        try player.enqueue(samples)
    }

    private func checkCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func playbackFinished(token: UUID) {
        guard generation == token else { return }
        player = nil
        setPreparing(false)
        setSpeaking(false)
    }

    private static func streamError(_ failure: PCMStreamFailure) -> String {
        switch failure {
        case .unexpectedAddress:
            return "The voice response came from an unexpected address. Playback was stopped."
        case .invalidResponse, .unexpectedContentType, .httpStatus:
            return "ElevenLabs returned an unreadable audio response. Capri's voice did not play."
        case .noAudio:
            return "ElevenLabs returned no audio for Capri's voice. Please try again."
        case .incompleteSample:
            return "Capri's voice stream ended unexpectedly. The full reply remains in chat."
        case .tooLong:
            return "Capri's voice stream exceeded the playback limit and was stopped. The full reply remains in chat."
        case .alreadyFinished, .playbackUnavailable:
            return "Capri's audio could not play on this Mac. The reply remains in chat."
        }
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func loadAPIKey() throws -> String {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw VoiceFailure("Add your ElevenLabs API key in Voice Settings to hear Capri's original voice. It needs access to this voice and Text to Speech.")
        }
        guard status == errSecSuccess else { throw Self.keychainFailure("read", status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw VoiceFailure("The saved ElevenLabs key could not be read. Save the key again in Voice Settings.")
        }
        return key
    }

    private static func keychainFailure(_ operation: String, status: OSStatus) -> VoiceFailure {
        VoiceFailure("macOS Keychain could not \(operation) the ElevenLabs key (status \(status)). Unlock your keychain or save the key again.")
    }

    static func makeRequest(text: String, voiceID: String, key: String?) throws -> URLRequest {
        // Validate again at the request boundary, including keys loaded from
        // older local stores. Never create an unauthenticated request or let
        // whitespace/control characters alter the authentication header.
        guard let key, !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw VoiceFailure("Add a valid ElevenLabs API key in Voice Settings before using cloud voice.")
        }
        guard !voiceID.isEmpty, voiceID.utf8.count <= 128,
              voiceID.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (65...90).contains($0.value) ||
                  (97...122).contains($0.value) || $0 == "_" || $0 == "-"
              }) else {
            throw VoiceFailure("The ElevenLabs voice ID is invalid. Restore Capri's original voice ID in Voice Settings.")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(voiceID)/stream"
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        guard let url = components.url else { throw VoiceFailure("The Capri voice request could not be prepared.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(SpeechBody(text: text, model_id: "eleven_multilingual_v2"))
        return request
    }

    private static func makeNetworkSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 20 * 60 + 30
        return URLSession(configuration: configuration, delegate: ElevenLabsNoRedirect(), delegateQueue: nil)
    }

    private static func serviceError(status: Int, body: Data) -> String {
        // Inspect error categories, but never echo a server response that might
        // contain submitted text or credentials into UI messages or logs.
        let detail = String(data: body.prefix(65_536), encoding: .utf8)?.lowercased() ?? ""
        if detail.contains("paid_plan_required") || detail.contains("free users cannot use library voices") || detail.contains("not available for free users") {
            return "ElevenLabs requires a paid plan to use this Voice Library voice through Capri. Free-plan credits do not unlock this voice's API access."
        }
        if detail.contains("quota_exceeded") || detail.contains("insufficient_credits") {
            return "Your ElevenLabs account is out of credits for Capri's voice. Add credits or check your plan; the reply remains in chat."
        }
        if status == 402 {
            return "ElevenLabs requires a paid plan or additional credits for this voice. Check your account's plan and credit balance; the reply remains in chat."
        }
        if detail.contains("voice_not_found") || detail.contains("voice_does_not_exist") || status == 404 {
            return "Capri's original voice is unavailable to this ElevenLabs account. Add or unlock this voice in ElevenLabs, then try again."
        }
        if detail.contains("missing_permissions") || status == 403 {
            return "This ElevenLabs key or account does not have permission to use Capri's voice. Allow Text to Speech and access to the selected voice."
        }
        if detail.contains("invalid_api_key") || status == 401 {
            return "ElevenLabs rejected the API key. Save a valid key in Voice Settings to use Capri's original voice."
        }
        if status == 429 {
            return "ElevenLabs is limiting voice requests right now. Wait a moment, then try again."
        }
        if (300...399).contains(status) {
            return "ElevenLabs returned a redirect. The request was stopped to keep your API key on api.elevenlabs.io."
        }
        return "ElevenLabs could not generate Capri's voice (HTTP \(status)). Check voice access, Text to Speech permission, and account credits."
    }

    private func setPreparing(_ value: Bool) {
        guard isPreparing != value else { return }
        isPreparing = value
        onPreparingChange?(value)
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onSpeakingChange?(value)
    }

    private struct SpeechBody: Encodable {
        let text: String
        let model_id: String
    }

    private struct VoiceFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Reject every redirect, including same-origin redirects: a speech request's
/// key and body must go only to the exact HTTPS API endpoint selected above.
private final class ElevenLabsNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

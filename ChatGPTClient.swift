import Foundation

struct ChatGPTModel: Equatable, Sendable {
    let id: String
    let displayName: String
}

struct ChatGPTClientError: LocalizedError, Sendable {
    let message: String
    var status: Int? = nil
    var code: String? = nil
    var param: String? = nil
    var requestID: String? = nil
    // Kept in memory for diagnosis, never logged automatically or persisted.
    var diagnosticBody: String? = nil
    var errorDescription: String? {
        var text = message
        if let code { text += " [\(code)]" }
        if let status, status >= 300 { text += " (HTTP \(status))" }
        if let requestID { text += " Request: \(requestID)" }
        return text
    }

    static func server(_ object: [String: Any], status: Int? = nil, requestID: String? = nil,
                       body: String? = nil) -> Self {
        let response = object["response"] as? [String: Any] ?? [:]
        let error = object["error"] as? [String: Any] ?? response["error"] as? [String: Any] ?? object
        var code = error["code"] as? String
        // Admission errors can use a top-level detail/message instead of the
        // standard error object. Classify only known request-option rejection
        // wording; never display the remote text or response body.
        if code == nil, status == 400 {
            let detail = [error["message"], error["detail"], object["message"], object["detail"]]
                .compactMap { $0 as? String }.joined(separator: " ").lowercased()
            let mentionsTier = detail.contains("service_tier") || detail.contains("service tier")
            let rejectsOption = ["unsupported", "not supported", "not allowed", "invalid", "not available"]
                .contains { detail.contains($0) }
            if mentionsTier && rejectsOption { code = "fast_tier_rejected" }
        }
        let message: String
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            message = "ChatGPT usage for this app has reached a limit. Check ChatGPT Settings → Usage before trying again."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            message = "ChatGPT couldn't check usage or account availability. Your sign-in is preserved; try again later."
        case "subscription_sharing_user_not_eligible":
            message = "ChatGPT plan usage isn't available for this account or workspace."
        case "subscription_sharing_unsupported_capability":
            message = "ChatGPT rejected an unsupported request option. No different model or billing method was used."
        case "fast_tier_rejected":
            message = "ChatGPT rejected Fast mode for this request. No slower retry or different billing method was used."
        default:
            switch status {
            case 400: message = "ChatGPT rejected a request option. No retry or different billing method was used."
            case 401: message = "ChatGPT didn't accept this account's authorization. Check the sign-in and granted plan permission."
            case 403: message = "ChatGPT policy or permissions prevented this request."
            case 429: message = "ChatGPT is limiting requests. Check usage or try again later."
            case 503: message = "ChatGPT routing is temporarily unavailable. Your sign-in is preserved."
            default: message = "ChatGPT could not complete the response. Please try again."
            }
        }
        return Self(message: message, status: status, code: code, param: error["param"] as? String,
                    requestID: requestID, diagnosticBody: body.map { String($0.prefix(8_192)) })
    }
}

/// Responses SSE decoder. UTF-8 bytes can arrive in arbitrary chunks; only a
/// response.completed event authorizes returning accumulated text.
struct ChatGPTResponseStream {
    private var lineBytes = Data()
    private var dataLines: [String] = []
    private var eventName = ""
    private var eventBytes = 0
    private var totalBytes = 0
    private var text = ""
    private var doneText = ""
    private var receivedEvent = false
    private(set) var completed = false
    private(set) var serviceTier: String?

    mutating func consume(_ chunk: Data) throws {
        for byte in chunk { try consume(byte: byte) }
    }

    mutating func consume(byte: UInt8) throws {
        totalBytes += 1
        guard totalBytes <= 8_000_000, lineBytes.count <= 2_000_000 else {
            throw ChatGPTClientError(message: "ChatGPT's response exceeded the local stream limit.")
        }
        if byte == 10 {
            if lineBytes.last == 13 { lineBytes.removeLast() }
            guard let line = String(data: lineBytes, encoding: .utf8) else {
                throw ChatGPTClientError(message: "ChatGPT returned invalid text encoding.", code: "stream_invalid_utf8")
            }
            lineBytes.removeAll(keepingCapacity: true)
            try consumeLine(line)
        } else { lineBytes.append(byte) }
    }

    mutating func finish() throws -> String {
        if !lineBytes.isEmpty {
            if lineBytes.last == 13 { lineBytes.removeLast() }
            guard let line = String(data: lineBytes, encoding: .utf8) else {
                throw ChatGPTClientError(message: "ChatGPT returned invalid text encoding.", code: "stream_invalid_utf8")
            }
            lineBytes.removeAll()
            try consumeLine(line)
        }
        if !dataLines.isEmpty { try dispatch() }
        guard completed else {
            throw ChatGPTClientError(
                message: receivedEvent
                    ? "ChatGPT's stream ended before the response completed. No partial reply was accepted."
                    : "ChatGPT's connection closed without returning any response events. Please try again.",
                code: receivedEvent ? "stream_interrupted" : "stream_empty")
        }
        let answer = (text.isEmpty ? doneText : text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ChatGPTClientError(message: "ChatGPT completed without a text reply.", code: "stream_no_text") }
        return answer
    }

    private mutating func consumeLine(_ line: String) throws {
        if line.isEmpty { try dispatch(); return }
        if line.hasPrefix(":") { return }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" { eventName = value }
        if field == "data" {
            eventBytes += value.utf8.count
            guard eventBytes <= 2_000_000 else { throw ChatGPTClientError(message: "ChatGPT returned an oversized stream event.") }
            dataLines.append(value)
        }
    }

    private mutating func dispatch() throws {
        let payload = dataLines.joined(separator: "\n")
        let name = eventName
        dataLines.removeAll(keepingCapacity: true); eventName = ""; eventBytes = 0
        guard !payload.isEmpty, payload != "[DONE]" else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ChatGPTClientError(message: "ChatGPT returned an unreadable stream event.", code: "stream_invalid_event")
        }
        receivedEvent = true
        let type = object["type"] as? String ?? name
        switch type {
        case "response.output_text.delta":
            if let delta = object["delta"] as? String { text += delta }
        case "response.refusal.delta":
            if let delta = object["delta"] as? String { text += delta }
        case "response.output_text.done", "response.refusal.done":
            doneText += object["text"] as? String ?? object["refusal"] as? String ?? ""
        case "response.failed", "error":
            throw ChatGPTClientError.server(object, body: payload)
        case "response.incomplete":
            let response = object["response"] as? [String: Any] ?? [:]
            let details = response["incomplete_details"] as? [String: Any] ?? [:]
            throw ChatGPTClientError(message: "ChatGPT stopped before completing the response. No partial reply was accepted.",
                                     code: details["reason"] as? String, diagnosticBody: String(payload.prefix(8_192)))
        case "response.completed":
            guard let response = object["response"] as? [String: Any],
                  response["status"] as? String == "completed" else {
                throw ChatGPTClientError(message: "ChatGPT returned an inconsistent completion event.", code: "stream_invalid_completion")
            }
            if let output = response["output"] as? [[String: Any]] {
                let finalText = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { content -> String? in
                    if content["type"] as? String == "output_text" { return content["text"] as? String }
                    if content["type"] as? String == "refusal" { return content["refusal"] as? String }
                    return nil
                }.joined(separator: "\n")
                if !finalText.isEmpty { text = finalText }
            }
            // Record only the tier of a verified completed response, not the
            // requested tier or an earlier lifecycle event. Bound the value
            // before exposing it to status/diagnostic surfaces.
            if let tier = response["service_tier"] as? String,
               tier.range(of: #"^[a-z_]{1,32}$"#, options: .regularExpression) != nil {
                serviceTier = tier
            }
            completed = true
        default: break // Reasoning and lifecycle events are never shown as chat.
        }
        guard text.utf8.count <= 2_000_000 else { throw ChatGPTClientError(message: "ChatGPT's reply exceeded the local text limit.") }
    }
}

/// Explicit ChatGPT-plan usage. No retries, model fallback, tools, credentials in
/// logs, persisted conversation IDs, cookies or redirected authenticated requests.
@MainActor
final class ChatGPTClient {
    enum TransportPhase {
        case models, startingReply, receivingReply

        var context: String {
            switch self {
            case .models: return "while checking available models"
            case .startingReply: return "while starting the reply"
            case .receivingReply: return "before the reply completed"
            }
        }

        var consequence: String {
            switch self {
            case .models: return "No reply request was sent."
            case .startingReply: return "Capri did not retry automatically."
            case .receivingReply: return "No partial reply was accepted."
            }
        }
    }

    private let tokenProvider: @MainActor () async throws -> String
    private let session: URLSession
    private(set) var lastServiceTier: String?

    init(tokenProvider: @escaping @MainActor () async throws -> String = { try await ChatGPTAuth.shared.validAccessToken() },
         protocolClasses: [AnyClass]? = nil) {
        self.tokenProvider = tokenProvider
        let config = URLSessionConfiguration.ephemeral
        // Reasoning can pause between response events. Give the explicit reply
        // request time to finish, while retaining a bounded overall lifetime.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.urlCredentialStorage = nil
        // Offline tests intercept every request. Normal callers keep the
        // system transport and the same fixed HTTPS endpoints.
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: ChatGPTNoRedirects(), delegateQueue: nil)
    }

    func availableModels() async throws -> [ChatGPTModel] {
        let request = try await authorizedRequest(path: "models")
        return try await loadModels(request)
    }

    private func loadModels(_ request: URLRequest) async throws -> [ChatGPTModel] {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Self.transportError(error, phase: .models) }
        try Task.checkCancellation()
        try Self.checkResponse(response, data: data)
        return try Self.decodeModels(data)
    }

    func reply(instructions: String, messages: [[String: String]], model: String) async throws -> String {
        lastServiceTier = nil
        var request = try await authorizedRequest(path: "responses")
        // Check entitlement with this exact bearer before every inference. No
        // stale catalog can authorize a changed account or silently pick a model.
        var catalogRequest = request
        catalogRequest.url = URL(string: "https://api.openai.com/v1/models")!
        catalogRequest.timeoutInterval = 30
        let catalog = try await loadModels(catalogRequest)
        guard catalog.contains(where: { $0.id == model }) else {
            throw ChatGPTClientError(message: "The selected model isn't available to this ChatGPT account. Choose one from Settings; no fallback was used.")
        }
        try Task.checkCancellation()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.requestBody(instructions: instructions, messages: messages, model: model)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { throw Self.transportError(error, phase: .startingReply) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ChatGPTClientError(message: "ChatGPT returned an unreadable response.") }
        guard http.url?.scheme == "https", http.url?.host == "api.openai.com" else {
            throw ChatGPTClientError(message: "ChatGPT returned an unexpected response address.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            do {
                for try await byte in bytes { try Task.checkCancellation(); if body.count >= 65_536 { break }; body.append(byte) }
            } catch { throw Self.transportError(error, phase: .receivingReply,
                                               requestID: http.value(forHTTPHeaderField: "x-request-id")) }
            try Self.checkResponse(http, data: body)
            throw ChatGPTClientError(message: "ChatGPT rejected the request.")
        }
        // Some authenticated responses omit Content-Type. Validate the SSE
        // events themselves, including the mandatory completed terminal event,
        // instead of rejecting a valid stream solely because a header is absent.
        var stream = ChatGPTResponseStream()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                try stream.consume(byte: byte)
                if stream.completed { break }
            }
            try Task.checkCancellation()
            let answer = try stream.finish()
            lastServiceTier = stream.serviceTier
            return answer
        } catch var error as ChatGPTClientError {
            error.status = http.statusCode
            error.requestID = http.value(forHTTPHeaderField: "x-request-id")
            throw error
        } catch { throw Self.transportError(error, phase: .receivingReply,
                                           requestID: http.value(forHTTPHeaderField: "x-request-id")) }
    }

    /// Use authored reasons and a numeric URL error code only. NSError userInfo,
    /// localized descriptions and failing URLs can contain private request data.
    static func transportError(_ error: Error, phase: TransportPhase, requestID: String? = nil) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let clientError = error as? ChatGPTClientError { return clientError }
        let reason: String
        let code: String?
        if let urlError = error as? URLError {
            code = "url_error_\(urlError.code.rawValue)"
            switch urlError.code {
            case .timedOut:
                reason = "The connection to ChatGPT timed out"
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                reason = "A network connection wasn't available to reach ChatGPT"
            case .networkConnectionLost:
                reason = "The connection to ChatGPT dropped"
            case .cannotFindHost, .dnsLookupFailed:
                reason = "Your Mac couldn't resolve ChatGPT's server address"
            case .cannotConnectToHost:
                reason = "Your Mac couldn't connect to ChatGPT's server"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                reason = "A secure connection to ChatGPT couldn't be established"
            case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData:
                reason = "ChatGPT returned an unreadable network response"
            default:
                reason = "ChatGPT's connection failed"
            }
        } else {
            code = nil
            reason = "An unexpected network error interrupted ChatGPT"
        }
        return ChatGPTClientError(message: "\(reason) \(phase.context). \(phase.consequence)",
                                  code: code, requestID: requestID)
    }

    static func requestBody(instructions: String, messages: [[String: String]], model: String) throws -> Data {
        guard !model.isEmpty, model.count <= 128,
              model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else {
            throw ChatGPTClientError(message: "Choose a valid model from this ChatGPT account's model list.")
        }
        guard !messages.isEmpty, messages.allSatisfy({ ["user", "assistant", "developer"].contains($0["role"] ?? "") && $0["content"] != nil }) else {
            throw ChatGPTClientError(message: "ChatGPT needs a valid conversation with no system-message items.")
        }
        var body: [String: Any] = [
            "model": model, "instructions": instructions,
            "input": messages.map { ["role": $0["role"]!, "content": $0["content"]!] },
            "store": false, "stream": true
        ]
        // The user selected Fast delivery, keeping the model's original
        // reasoning defaults. Unsupported Fast requests fail explicitly;
        // they are never retried with another tier or billing method.
        if model == "gpt-6.1-sol" { body["service_tier"] = "priority" }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func decodeModels(_ data: Data) throws -> [ChatGPTModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            throw ChatGPTClientError(message: "ChatGPT returned an unreadable account model catalog.")
        }
        var seen = Set<String>()
        let visible = models.compactMap { item -> ChatGPTModel? in
            guard item["visibility"] as? String == "list", let id = item["slug"] as? String, !id.isEmpty,
                  let displayName = item["display_name"] as? String, !displayName.isEmpty, seen.insert(id).inserted else { return nil }
            return ChatGPTModel(id: id, displayName: displayName)
        }
        guard !visible.isEmpty else { throw ChatGPTClientError(message: "No available ChatGPT models were returned for this account.") }
        return visible
    }

    private func authorizedRequest(path: String) async throws -> URLRequest {
        try Task.checkCancellation()
        let token = try await tokenProvider()
        try Task.checkCancellation()
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw ChatGPTClientError(message: "Sign in to ChatGPT to enable this connection.")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData)
        // Set the request explicitly: URLRequest's default timeout must not
        // impose a shorter limit than the session's reasoning allowance.
        request.timeoutInterval = path == "responses" ? 300 : 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "api.openai.com" else {
            throw ChatGPTClientError(message: "ChatGPT returned an unexpected response address.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            throw ChatGPTClientError.server(object, status: http.statusCode,
                requestID: http.value(forHTTPHeaderField: "x-request-id"), body: String(data: data, encoding: .utf8))
        }
    }
}

private final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

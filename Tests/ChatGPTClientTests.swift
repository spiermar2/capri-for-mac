import Foundation

@main
struct ChatGPTClientTests {
    @MainActor static func main() async throws {
        var count = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS \(label)") }
        func throwsError(_ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label) } catch { count += 1; print("PASS \(label)") }
        }
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hey, choom.\"}\n\n"
        let complete = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        var stream = ChatGPTResponseStream()
        try stream.consume(Data((delta + complete).utf8))
        let ordinaryText = try stream.finish()
        expect(ordinaryText == "Hey, choom.", "delta text requires completed event")
        var chunked = ChatGPTResponseStream()
        let unicode = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Nova ✦ café\"}\r\n\r\n" + complete
        for byte in unicode.utf8 { try chunked.consume(Data([byte])) }
        let chunkedText = try chunked.finish()
        expect(chunkedText == "Nova ✦ café", "arbitrary UTF8 chunks and CRLF decode correctly")
        var multiline = ChatGPTResponseStream()
        try multiline.consume(Data(": keepalive\nid: 9\nevent: response.output_text.delta\ndata: {\"delta\":\ndata: \"Two lines\"}\n\n".utf8))
        try multiline.consume(Data(complete.utf8))
        let multilineText = try multiline.finish()
        expect(multilineText == "Two lines", "multiline data and event field combine correctly")
        throwsError("DONE alone is not completed inference") { var s = ChatGPTResponseStream(); try s.consume(Data((delta + "data: [DONE]\n\n").utf8)); _ = try s.finish() }
        throwsError("interrupted partial reply is rejected") { var s = ChatGPTResponseStream(); try s.consume(Data(delta.utf8)); _ = try s.finish() }
        throwsError("failed event after partial text is rejected") { var s = ChatGPTResponseStream(); try s.consume(Data((delta + "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n").utf8)) }
        throwsError("explicit error event is rejected") { var s = ChatGPTResponseStream(); try s.consume(Data("event: error\ndata: {\"code\":\"broken\"}\n\n".utf8)) }
        throwsError("incomplete event never promotes partial output") { var s = ChatGPTResponseStream(); try s.consume(Data((delta + "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n").utf8)) }
        throwsError("malformed JSON is not ignored") { var s = ChatGPTResponseStream(); try s.consume(Data("data: {bad}\n\n".utf8)) }
        throwsError("empty completed response is rejected") { var s = ChatGPTResponseStream(); try s.consume(Data(complete.utf8)); _ = try s.finish() }
        throwsError("non-completed status cannot masquerade as completion") { var s = ChatGPTResponseStream(); try s.consume(Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"failed\"}}\n\n".utf8)) }
        throwsError("missing status is not accepted as completion") { var s = ChatGPTResponseStream(); try s.consume(Data("data: {\"type\":\"response.completed\",\"response\":{}}\n\n".utf8)) }
        do {
            var s = ChatGPTResponseStream()
            try s.consume(Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"param\":\"model\"}}}\n\n".utf8))
            preconditionFailure("usage error should throw")
        } catch let error as ChatGPTClientError {
            expect(error.code == "subscription_sharing_usage_limit_exceeded" && error.param == "model", "structured error code and parameter are retained")
        }
        var finalOnly = ChatGPTResponseStream()
        try finalOnly.consume(Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Final reply.\"}]}]}}".utf8))
        let finalText = try finalOnly.finish()
        expect(finalText == "Final reply.", "final output works with no trailing newline or deltas")
        var doneOnly = ChatGPTResponseStream()
        try doneOnly.consume(Data(("data: {\"type\":\"response.output_text.done\",\"text\":\"Done text\"}\n\n" + complete + "data: [DONE]\n\n").utf8))
        let doneText = try doneOnly.finish()
        expect(doneText == "Done text", "text done plus response completed is valid")
        let error = ChatGPTClientError.server(["detail": "admission failed"], status: 403, requestID: "test-request", body: "{\"detail\":\"admission failed\"}")
        expect(error.status == 403 && error.requestID == "test-request" && error.diagnosticBody?.contains("detail") == true, "nonstandard admission error preserves diagnostics")
        let body = try ChatGPTClient.requestBody(instructions: "Be Capri.", messages: [["role": "user", "content": "hey"]], model: "gpt-6.1-sol")
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        expect(Set(json.keys) == ["model", "instructions", "input", "store", "stream", "service_tier"], "only supported request fields are emitted")
        expect(json["store"] as? Bool == false && json["stream"] as? Bool == true, "stateless streaming is required")
        expect(json["model"] as? String == "gpt-6.1-sol", "explicit model is preserved")
        expect(json["service_tier"] as? String == "priority",
               "GPT-6.1 Sol requests Fast delivery using the documented priority alias")
        expect(json["reasoning"] == nil, "Fast delivery preserves original model reasoning defaults")
        let otherBody = try ChatGPTClient.requestBody(instructions: "Be Capri.",
            messages: [["role": "user", "content": "hey"]], model: "other-account-model")
        let otherJSON = try JSONSerialization.jsonObject(with: otherBody) as! [String: Any]
        expect(otherJSON["reasoning"] == nil && otherJSON["service_tier"] == nil,
               "other account-selected models preserve reasoning and service defaults")
        let tierRejection = ChatGPTClientError.server(["detail": "Unsupported service_tier: priority; PRIVATE_PAYLOAD"], status: 400)
        expect(tierRejection.code == "fast_tier_rejected" && !tierRejection.localizedDescription.contains("PRIVATE_PAYLOAD"),
               "nonstandard tier rejection is classified without exposing server text")
        let nonTierRejection = ChatGPTClientError.server(["message": "Invalid conversation input; PRIVATE_PAYLOAD"], status: 400)
        expect(nonTierRejection.code == nil && nonTierRejection.message.contains("request option") && !nonTierRejection.localizedDescription.contains("PRIVATE_PAYLOAD"),
               "other nonstandard 400 errors are not falsely blamed on Fast")
        let weakTierMention = ChatGPTClientError.server(["detail": "service_tier priority processed"], status: 400)
        expect(weakTierMention.code == nil, "tier mention alone is insufficient to classify a rejection")
        for tier in ["fast", "priority", "default"] {
            var tierStream = ChatGPTResponseStream()
            try tierStream.consume(Data((delta + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"service_tier\":\"\(tier)\"}}\n\n").utf8))
            _ = try tierStream.finish()
            expect(tierStream.serviceTier == tier, "verified completion records actual \(tier) tier")
        }
        expect(stream.serviceTier == nil, "missing returned tier is not assumed to be Fast")
        var earlyTier = ChatGPTResponseStream()
        try earlyTier.consume(Data("data: {\"type\":\"response.created\",\"response\":{\"service_tier\":\"fast\"}}\n\n".utf8))
        expect(earlyTier.serviceTier == nil, "early lifecycle tier cannot verify completed Fast delivery")
        var unsafeTier = ChatGPTResponseStream()
        try unsafeTier.consume(Data((delta + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"service_tier\":\"private?token=secret\"}}\n\n").utf8))
        _ = try unsafeTier.finish()
        expect(unsafeTier.serviceTier == nil, "unexpected tier metadata is bounded before diagnostics")
        throwsError("system message input is rejected") { _ = try ChatGPTClient.requestBody(instructions: "", messages: [["role": "system", "content": "no"]], model: "gpt-6.1-sol") }
        let catalog = Data("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"GPT-6.1 Sol\",\"visibility\":\"list\"},{\"slug\":\"hidden\",\"display_name\":\"Hidden\",\"visibility\":\"hidden\"},{\"slug\":\"other\",\"display_name\":\"Other\",\"visibility\":\"list\"}]}".utf8)
        let models = try ChatGPTClient.decodeModels(catalog)
        expect(models.map(\.id) == ["gpt-6.1-sol", "other"], "visible catalog preserves account ordering")
        expect(models.first?.displayName == "GPT-6.1 Sol", "catalog display name is preserved")
        throwsError("API-key-style catalog is not mistaken for ChatGPT entitlement") { _ = try ChatGPTClient.decodeModels(Data("{\"data\":[{\"id\":\"gpt-6.1-sol\"}]}".utf8)) }

        let timeout = ChatGPTClient.transportError(URLError(.timedOut), phase: .startingReply) as! ChatGPTClientError
        expect(timeout.message.contains("timed out") && timeout.message.contains("starting the reply"),
               "reply startup timeout has a specific reason and phase")
        expect(timeout.code == "url_error_-1001" && timeout.message.contains("did not retry automatically"),
               "timeout retains its safe numeric diagnostic without promising a free retry")
        let catalogTimeout = ChatGPTClient.transportError(URLError(.timedOut), phase: .models) as! ChatGPTClientError
        expect(catalogTimeout.message.contains("checking available models") && catalogTimeout.message.contains("No reply request was sent"),
               "catalog failures explain that inference was never sent")
        let dropped = ChatGPTClient.transportError(URLError(.networkConnectionLost), phase: .receivingReply,
                                                   requestID: "request-test-123") as! ChatGPTClientError
        expect(dropped.message.contains("dropped") && dropped.message.contains("before the reply completed"),
               "dropped stream is distinguished from startup timeout")
        expect(dropped.requestID == "request-test-123" && dropped.code == "url_error_-1005",
               "known request ID and numeric connection-loss code survive stream failure")
        let offline = ChatGPTClient.transportError(URLError(.notConnectedToInternet), phase: .models) as! ChatGPTClientError
        expect(offline.message.contains("network connection wasn't available") && offline.code == "url_error_-1009",
               "offline connection produces an actionable distinct explanation")
        let dns = ChatGPTClient.transportError(URLError(.dnsLookupFailed), phase: .startingReply) as! ChatGPTClientError
        expect(dns.message.contains("resolve ChatGPT's server address"), "DNS failures are recognizable")
        let tls = ChatGPTClient.transportError(URLError(.serverCertificateUntrusted), phase: .startingReply) as! ChatGPTClientError
        expect(tls.message.contains("secure connection") && !tls.message.contains("disable"),
               "TLS failure is clear without suggesting certificate bypass")
        let privateURL = "https://example.invalid/private?token=SHOULD_NOT_LEAK"
        let privateError = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                                   userInfo: [NSLocalizedDescriptionKey: "SHOULD_NOT_LEAK",
                                              NSURLErrorFailingURLErrorKey: URL(string: privateURL)!])
        let safeError = ChatGPTClient.transportError(privateError, phase: .startingReply) as! ChatGPTClientError
        expect(safeError.code == "url_error_-1001", "bridged Foundation network errors retain the numeric code")
        expect(!safeError.localizedDescription.contains("SHOULD_NOT_LEAK") && safeError.diagnosticBody == nil,
               "transport messages never expose descriptions, failing URLs, or credentials")
        let unknownError = ChatGPTClient.transportError(NSError(domain: "SHOULD_NOT_LEAK", code: 123,
                                                               userInfo: [NSLocalizedDescriptionKey: privateURL]),
                                                       phase: .startingReply) as! ChatGPTClientError
        expect(unknownError.code == nil && !unknownError.localizedDescription.contains("SHOULD_NOT_LEAK"),
               "unknown error domains are not copied into display diagnostics")
        expect(ChatGPTClient.transportError(URLError(.cancelled), phase: .receivingReply) is CancellationError,
               "Foundation cancellation remains cancellation")
        expect(ChatGPTClient.transportError(CancellationError(), phase: .models) is CancellationError,
               "task cancellation remains cancellation")
        let originalClientError = ChatGPTClientError(message: "Authored issue", code: "test_code")
        let preserved = ChatGPTClient.transportError(originalClientError, phase: .receivingReply) as! ChatGPTClientError
        expect(preserved.code == "test_code" && preserved.message == "Authored issue",
               "authored parser or server errors are not replaced by network errors")
        do {
            var s = ChatGPTResponseStream()
            try s.consume(Data(": keepalive\n\n".utf8))
            _ = try s.finish()
            preconditionFailure("empty stream should throw")
        } catch let error as ChatGPTClientError {
            expect(error.code == "stream_empty", "connection close with no events has a distinct diagnostic")
        }
        do {
            var s = ChatGPTResponseStream()
            try s.consume(Data(delta.utf8))
            _ = try s.finish()
            preconditionFailure("partial stream should throw")
        } catch let error as ChatGPTClientError {
            expect(error.code == "stream_interrupted", "truncated stream is distinguished from an empty stream")
        }
        do {
            var s = ChatGPTResponseStream()
            try s.consume(Data("data: {broken}\n\n".utf8))
            preconditionFailure("malformed stream should throw")
        } catch let error as ChatGPTClientError {
            expect(error.code == "stream_invalid_event", "malformed SSE JSON is distinguished from network interruption")
        }
        let client = ChatGPTClient(tokenProvider: { preconditionFailure("cancelled call must not ask for credentials") })
        let cancelled = Task { @MainActor in try await client.availableModels() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancellation must be preserved") }
        catch is CancellationError { expect(true, "cancelled request stops before credential or network access") }
        print("\(count) ChatGPT client checks passed; no network or account calls")
    }
}

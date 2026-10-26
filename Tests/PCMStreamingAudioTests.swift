import Foundation

@main
struct PCMStreamingAudioTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
            print("PASS \(label)")
        }
        func expectError(_ error: PCMStreamFailure, _ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label) }
            catch let actual as PCMStreamFailure { expect(actual == error, label) }
            catch { preconditionFailure("\(label): unexpected error") }
        }
        func response(_ status: Int = 200, _ type: String? = "audio/pcm", host: String = "api.elevenlabs.io") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://\(host)/v1/text-to-speech/test/stream?output_format=pcm_24000")!,
                            statusCode: status, httpVersion: nil,
                            headerFields: type.map { ["Content-Type": $0] })!
        }
        func bytes(_ samples: [Int16]) -> [UInt8] {
            samples.flatMap { value in
                let bits = UInt16(bitPattern: value)
                return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
            }
        }
        let expectedSamples: [Int16] = [0, 1, -1, .min, .max, -10_000, 10_000, 234, -234]
        let data = bytes(expectedSamples)
        for boundary in 1...data.count {
            var decoder = try PCMStreamDecoder(response: response(), chunkFrames: 4)
            var decoded: [Float] = []
            var firstChunkBeforeEOF = false
            for start in stride(from: 0, to: data.count, by: boundary) {
                for byte in data[start..<min(start + boundary, data.count)] {
                    if let chunk = try decoder.append(byte) {
                        firstChunkBeforeEOF = firstChunkBeforeEOF || !decoder.isFinished
                        decoded += chunk
                    }
                }
            }
            if let tail = try decoder.finish() { decoded += tail }
            expect(decoded == expectedSamples.map { Float($0) / 32_768 }, "signed little-endian PCM survives boundary \(boundary)")
            expect(firstChunkBeforeEOF, "first audio chunk is available before EOF at boundary \(boundary)")
        }

        var short = try PCMStreamDecoder(response: response(), chunkFrames: 100)
        for byte in bytes([Int16.min, Int16.max]) {
            let chunk = try short.append(byte)
            expect(chunk == nil, "short reply waits for complete final chunk")
        }
        let shortTail = try short.finish()
        expect(shortTail == [-1, Float(Int16.max) / 32_768], "short final buffer retains every complete sample")
        expectError(.alreadyFinished, "no samples accepted after EOF") { _ = try short.append(0) }
        expectError(.alreadyFinished, "EOF cannot be emitted twice") { _ = try short.finish() }
        var empty = try PCMStreamDecoder(response: response())
        expectError(.noAudio, "empty audio is rejected") { _ = try empty.finish() }
        var odd = try PCMStreamDecoder(response: response(), chunkFrames: 1)
        _ = try odd.append(1)
        expectError(.incompleteSample, "truncated half-sample is rejected") { _ = try odd.finish() }
        var bounded = try PCMStreamDecoder(response: response(), chunkFrames: 1, maximumBytes: 2)
        _ = try bounded.append(0); _ = try bounded.append(0)
        expectError(.tooLong, "total audio length is bounded") { _ = try bounded.append(0) }
        for status in [301, 400, 401, 403, 429, 500] {
            expectError(.httpStatus(status), "HTTP \(status) cannot be interpreted as PCM") { _ = try PCMStreamDecoder(response: response(status)) }
        }
        for type in ["application/json", "text/html", "audio/mpeg", "audio/wav", "audio/flac", "audio/ogg"] {
            expectError(.unexpectedContentType, "\(type) never enters raw audio playback") { _ = try PCMStreamDecoder(response: response(200, type)) }
        }
        for type in ["application/octet-stream", "application/pcm", "audio/pcm", "audio/x-pcm", "audio/raw"] {
            _ = try PCMStreamDecoder(response: response(200, type))
            expect(true, "supported PCM type \(type)")
        }
        expectError(.unexpectedAddress, "unexpected response host is rejected") { _ = try PCMStreamDecoder(response: response(host: "example.com")) }

        var ledger = PCMPlaybackLedger()
        let first = ledger.schedule(frames: 2400)!
        let second = ledger.schedule(frames: 1200)!
        expect(ledger.queuedFrames == 3600, "queued audio frame count is exact")
        ledger.finishInput()
        expect(!ledger.isComplete, "network EOF does not finish queued playback")
        expect(ledger.schedule(frames: 100) == nil, "cannot schedule after input EOF")
        expect(ledger.played(first) && !ledger.isComplete, "first completed buffer leaves remaining audio active")
        expect(!ledger.played(first) && ledger.queuedFrames == 1200, "duplicate callbacks cannot drain a new buffer")
        expect(ledger.played(second) && ledger.isComplete, "last played buffer finishes only after EOF")
        var waiting = PCMPlaybackLedger()
        let waitingTicket = waiting.schedule(frames: 30)!
        _ = waiting.played(waitingTicket)
        expect(!waiting.isComplete, "temporary network underrun does not finish the utterance")
        waiting.finishInput()
        expect(waiting.isComplete, "EOF after drain completes the utterance")
        var canceled = PCMPlaybackLedger()
        let canceledTicket = canceled.schedule(frames: 300)!
        canceled.stop()
        canceled.finishInput()
        expect(canceled.queuedFrames == 0 && !canceled.isComplete, "stop drops queued audio without natural completion")
        expect(!canceled.played(canceledTicket), "stale callbacks cannot revive stopped playback")
        expect(canceled.schedule(frames: 100) == nil, "stopped player rejects further audio")
        var replacement = PCMPlaybackLedger()
        let replacementTicket = replacement.schedule(frames: 100)!
        expect(!replacement.played(canceledTicket) && replacement.queuedFrames == 100, "old utterance callback cannot affect replacement")
        expect(replacement.played(replacementTicket), "replacement accepts only its own ticket")

        let request = try ElevenLabsVoice.makeRequest(text: "Test only", voiceID: ElevenLabsVoice.originalVoiceID, key: "offline-placeholder")
        expect(request.url?.path.hasSuffix("/stream") == true && request.httpMethod == "POST", "voice uses the streaming POST endpoint")
        expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "output_format", value: "pcm_24000")], "request selects only PCM24k without deprecated latency options")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect(body["text"] as? String == "Test only" && body["model_id"] as? String == "eleven_multilingual_v2", "original voice model and input text remain unchanged")
        expect(body["voice_settings"] as? [String: Double] == ["speed": ElevenLabsVoice.defaultSpeed], "streaming request changes only the speaking pace")
        expect(request.value(forHTTPHeaderField: "xi-api-key") == "offline-placeholder", "test request uses only a synthetic credential")

        // Real AVAudioEngine/AVAudioPlayerNode with its volume at zero. This
        // tests scheduling, callback timing and stop without network/Keychain.
        var playbackEvents: [Bool] = []
        var completions = 0
        let player = try PCMStreamPlayer(volume: 0, onPlaybackChange: { playbackEvents.append($0) }, onCompletion: { completions += 1 })
        let silence = [Float](repeating: 0, count: PCMStreamDecoder.chunkFrames)
        try player.enqueue(silence)
        expect(playbackEvents == [true] && completions == 0, "muted engine starts while input stream remains open")
        let drainDeadline = Date().addingTimeInterval(3)
        while player.queuedFrames > 0 && Date() < drainDeadline { try await Task.sleep(for: .milliseconds(10)) }
        expect(player.queuedFrames == 0 && completions == 0 && playbackEvents.last == false, "drained audio waits for network EOF without a finish callback")
        try player.enqueue([Float](repeating: 0, count: 240))
        expect(playbackEvents.last == true, "player resumes after a network gap")
        player.finishInput()
        expect(completions == 0, "final buffer is not declared finished at network EOF")
        let finishDeadline = Date().addingTimeInterval(3)
        while completions == 0 && Date() < finishDeadline { try await Task.sleep(for: .milliseconds(10)) }
        expect(completions == 1 && playbackEvents.last == false && player.isStopped, "device playback completion ends the utterance exactly once")

        var canceledCompletions = 0
        var canceledEvents: [Bool] = []
        let stopped = try PCMStreamPlayer(volume: 0, onPlaybackChange: { canceledEvents.append($0) }, onCompletion: { canceledCompletions += 1 })
        for _ in 0..<16 { try stopped.enqueue(silence) }
        expect(!stopped.canAccept(frameCount: silence.count), "scheduled real audio queue never exceeds two seconds")
        stopped.stop()
        expect(stopped.queuedFrames == 0 && canceledEvents == [true, false], "stop immediately clears queued audio and speaking state")
        try await Task.sleep(for: .milliseconds(200))
        expect(canceledCompletions == 0 && canceledEvents == [true, false], "late real-engine callbacks cannot complete or restart stopped voice")
        print("\(checks) streaming-voice checks passed; no network or Keychain access; engine muted")
    }
}

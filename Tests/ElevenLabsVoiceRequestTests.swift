import Foundation

@main
struct ElevenLabsVoiceRequestTests {
    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
            print("PASS \(label)")
        }
        func request(speed: Double = ElevenLabsVoice.defaultSpeed) throws -> URLRequest {
            try ElevenLabsVoice.makeRequest(text: "Speed test only", voiceID: "offline_voice", key: "offline-placeholder", speed: speed)
        }
        func body(_ request: URLRequest) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        let baseline = try request()
        let baselineBody = try body(baseline)
        expect(Set(baselineBody.keys) == ["text", "model_id", "voice_settings"], "request has only text, model and voice overrides")
        expect(baselineBody["text"] as? String == "Speed test only", "input text is unchanged")
        expect(baselineBody["model_id"] as? String == "eleven_multilingual_v2", "selected synthesis model is unchanged")
        expect(baselineBody["voice_settings"] as? [String: Double] == ["speed": 1.18], "default pace is 1.18x with no stability or style override")
        expect(baseline.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/offline_voice/stream?output_format=pcm_24000", "selected voice, official endpoint and streaming PCM stay unchanged")
        expect(baseline.httpMethod == "POST" && baseline.value(forHTTPHeaderField: "xi-api-key") == "offline-placeholder", "authentication stays on the same streaming POST request")

        for (input, expected, name) in [
            (0.7, 0.7, "minimum"), (1.0, 1.0, "normal"), (1.18, 1.18, "faster default"),
            (1.2, 1.2, "maximum"), (-100.0, 0.7, "below range"), (100.0, 1.2, "above range"),
            (Double.nan, 1.18, "NaN"), (Double.infinity, 1.18, "positive infinity"),
            (-Double.infinity, 1.18, "negative infinity")
        ] {
            let encoded = try body(request(speed: input))
            expect(encoded["voice_settings"] as? [String: Double] == ["speed": expected], "\(name) is safely encoded at the request boundary")
        }
        // Setting pace must be local-only and must not trigger playback or a key read.
        let voice = ElevenLabsVoice()
        var events = 0
        voice.onSpeakingChange = { _ in events += 1 }
        voice.onPreparingChange = { _ in events += 1 }
        voice.onError = { _ in events += 1 }
        expect(voice.speed == 1.18, "new voice instances start at the faster pace")
        voice.speed = 1.07
        expect(voice.speed == 1.07, "an in-range preference is preserved")
        voice.speed = 2
        expect(voice.speed == 1.2, "stored pace is bounded")
        voice.speed = .nan
        expect(voice.speed == 1.18, "invalid stored pace recovers to default")
        expect(events == 0 && !voice.isSpeaking && !voice.isPreparing, "changing pace does not start synthesis or playback")
        do {
            _ = try ElevenLabsVoice.makeRequest(text: "No real account", voiceID: "offline_voice", key: nil, speed: 1.2)
            preconditionFailure("pace must not bypass credential validation")
        } catch {
            expect(true, "pace does not bypass missing-credential rejection")
        }
        print("\(checks) voice-request checks passed; no network requests or Keychain access")
    }
}

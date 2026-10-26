import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Local-only voice support. The app must call startListening in response to a
/// user action; creating this object does not request either permission.
@MainActor
final class CompanionVoice: NSObject, NSSpeechSynthesizerDelegate {
    var onTranscript: ((String, Bool) -> Void)?
    var onListeningChange: ((Bool) -> Void)?
    var onSpeakingChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isListening = false
    var enabled = true {
        didSet {
            if !enabled {
                stopListening()
                stopSpeaking()
            }
        }
    }
    /// A voice already installed in macOS. Nil uses the system default voice.
    var voiceIdentifier: String?

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var audioRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var synthesizer: NSSpeechSynthesizer?
    private var timeoutTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var session = UUID()
    private var authorizationPending = false
    private var installedTap = false
    private var lastTranscript = ""
    private var finalDelivered = false
    private var speaking = false

    func startListening() {
        guard enabled else {
            onError?("Voice is turned off. You can still type a message.")
            return
        }
        guard !isListening, !authorizationPending else { return }
        stopSpeaking()
        cancelRecognition()
        let token = session
        lastTranscript = ""
        finalDelivered = false

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.supportsOnDeviceRecognition else {
            onError?("On-device speech recognition is unavailable for this Mac or language. Please use typed chat.")
            return
        }
        self.recognizer = recognizer
        authorizationPending = true

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicrophonePermission(for: token)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.session == token, self.authorizationPending else { return }
                    if status == .authorized {
                        self.requestMicrophonePermission(for: token)
                    } else {
                        self.permissionFailed("Speech recognition permission is unavailable. You can enable it in System Settings → Privacy & Security → Speech Recognition, or use typed chat.")
                    }
                }
            }
        default:
            permissionFailed("Speech recognition permission is unavailable. You can enable it in System Settings → Privacy & Security → Speech Recognition, or use typed chat.")
        }
    }

    /// Stops the microphone immediately, then briefly allows the recognizer to
    /// finish the last words. The transcript is only a draft for the caller.
    func stopListening() {
        authorizationPending = false
        guard audioRequest != nil || recognitionTask != nil else {
            session = UUID() // Discard an in-flight permission callback.
            setListening(false)
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        stopAudioInput()
        setListening(false)
        audioRequest?.endAudio()
        recognitionTask?.finish()
        let token = session
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.session == token else { return }
            self.deliverFinalIfNeeded()
            self.cancelRecognition()
        }
    }

    func speak(_ text: String) {
        guard enabled else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stopListening()
        stopSpeaking()
        let voice = voiceIdentifier.map { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
        let speech = NSSpeechSynthesizer(voice: voice) ?? NSSpeechSynthesizer()
        speech.delegate = self
        synthesizer = speech
        if speech.startSpeaking(text) {
            setSpeaking(true)
        } else {
            speech.delegate = nil
            synthesizer = nil
            onError?("macOS could not start speaking. The reply is still available in chat.")
        }
    }

    func stopSpeaking() {
        // Each utterance gets a new synthesizer, so a late finish callback from
        // an interrupted utterance cannot change the next utterance's state.
        let previous = synthesizer
        synthesizer = nil
        previous?.delegate = nil
        previous?.stopSpeaking()
        setSpeaking(false)
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard sender === synthesizer else { return }
        sender.delegate = nil
        synthesizer = nil
        setSpeaking(false)
    }

    private func requestMicrophonePermission(for token: UUID) {
        guard session == token, authorizationPending, enabled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecognition(for: token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.session == token, self.authorizationPending else { return }
                    if granted {
                        self.beginRecognition(for: token)
                    } else {
                        self.permissionFailed("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone, or use typed chat.")
                    }
                }
            }
        default:
            permissionFailed("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone, or use typed chat.")
        }
    }

    private func beginRecognition(for token: UUID) {
        guard session == token, authorizationPending, enabled, let recognizer else { return }
        authorizationPending = false
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            onError?("On-device speech recognition is currently unavailable. Please use typed chat.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Never fall back to Apple's server-based speech recognition.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No usable microphone was found. Connect a microphone or use typed chat.")
            return
        }
        audioEngine = engine
        audioRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        installedTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Copy values before crossing onto the UI actor.
            let transcript = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.receive(transcript: transcript, final: final, error: errorMessage, token: token)
            }
        }
        do {
            engine.prepare()
            try engine.start()
            setListening(true)
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self, self.session == token else { return }
                self.stopListening()
            }
        } catch {
            cancelRecognition()
            onError?("The microphone could not start: \(error.localizedDescription)")
        }
    }

    private func receive(transcript: String?, final: Bool, error: String?, token: UUID) {
        guard session == token, audioRequest != nil else { return }
        if let transcript {
            lastTranscript = transcript
            if final {
                deliverFinalIfNeeded()
            } else {
                onTranscript?(transcript, false)
            }
        }
        if final {
            deliverFinalIfNeeded()
            cancelRecognition()
        } else if let error {
            let wasListening = isListening
            deliverFinalIfNeeded()
            cancelRecognition()
            if wasListening {
                onError?("On-device recognition stopped: \(error). You can review the draft or type your message.")
            }
        }
    }

    private func deliverFinalIfNeeded() {
        guard !finalDelivered else { return }
        finalDelivered = true
        if !lastTranscript.isEmpty { onTranscript?(lastTranscript, true) }
    }

    private func stopAudioInput() {
        audioEngine?.stop()
        if installedTap {
            audioEngine?.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
        audioEngine = nil
    }

    private func cancelRecognition() {
        session = UUID()
        authorizationPending = false
        timeoutTask?.cancel()
        timeoutTask = nil
        finishTask?.cancel()
        finishTask = nil
        stopAudioInput()
        audioRequest?.endAudio()
        audioRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        setListening(false)
    }

    private func permissionFailed(_ message: String) {
        authorizationPending = false
        onError?(message)
    }

    private func setListening(_ value: Bool) {
        guard isListening != value else { return }
        isListening = value
        onListeningChange?(value)
    }

    private func setSpeaking(_ value: Bool) {
        guard speaking != value else { return }
        speaking = value
        onSpeakingChange?(value)
    }
}

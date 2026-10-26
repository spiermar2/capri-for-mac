import Foundation
@preconcurrency import AVFoundation

enum PCMStreamFailure: Error, Equatable {
    case invalidResponse, unexpectedAddress, httpStatus(Int), unexpectedContentType
    case noAudio, incompleteSample, tooLong, alreadyFinished, playbackUnavailable
}

/// Raw ElevenLabs PCM is signed 16-bit little-endian, mono, at 24 kHz.
/// Keeps at most one 120 ms chunk, even when network boundaries split a sample.
struct PCMStreamDecoder {
    static let sampleRate = 24_000
    static let chunkFrames = 2_880
    static let maximumBytes = sampleRate * 2 * 20 * 60

    private let targetFrames: Int
    private let maximumBytes: Int
    private var firstByte: UInt8?
    private var samples: [Float] = []
    private(set) var byteCount = 0
    private(set) var isFinished = false

    init(response: HTTPURLResponse, chunkFrames: Int = Self.chunkFrames,
         maximumBytes: Int = Self.maximumBytes) throws {
        guard response.url?.scheme == "https", response.url?.host == "api.elevenlabs.io" else {
            throw PCMStreamFailure.unexpectedAddress
        }
        guard (200...299).contains(response.statusCode) else {
            throw PCMStreamFailure.httpStatus(response.statusCode)
        }
        if let type = response.mimeType?.lowercased(),
           !["application/octet-stream", "application/pcm", "audio/pcm", "audio/x-pcm", "audio/raw"].contains(type) {
            throw PCMStreamFailure.unexpectedContentType
        }
        precondition(chunkFrames > 0 && maximumBytes > 0)
        targetFrames = chunkFrames
        self.maximumBytes = maximumBytes
        samples.reserveCapacity(chunkFrames)
    }

    mutating func append(_ byte: UInt8) throws -> [Float]? {
        guard !isFinished else { throw PCMStreamFailure.alreadyFinished }
        guard byteCount < maximumBytes else { throw PCMStreamFailure.tooLong }
        byteCount += 1
        guard let low = firstByte else {
            firstByte = byte
            return nil
        }
        firstByte = nil
        let signed = Int16(bitPattern: UInt16(low) | UInt16(byte) << 8)
        samples.append(Float(signed) / 32_768)
        guard samples.count == targetFrames else { return nil }
        return takeSamples()
    }

    mutating func finish() throws -> [Float]? {
        guard !isFinished else { throw PCMStreamFailure.alreadyFinished }
        isFinished = true
        guard firstByte == nil else { throw PCMStreamFailure.incompleteSample }
        guard byteCount > 0 else { throw PCMStreamFailure.noAudio }
        return samples.isEmpty ? nil : takeSamples()
    }

    private mutating func takeSamples() -> [Float] {
        let result = samples
        samples = []
        samples.reserveCapacity(targetFrames)
        return result
    }
}

/// Separates stream EOF from the audio device consuming the last buffer.
/// Tickets also reject callbacks left behind by stop or a replaced utterance.
struct PCMPlaybackLedger {
    struct Ticket: Hashable, Sendable { let generation: UUID; let id: UUID }
    private(set) var generation = UUID()
    private var pending: [Ticket: Int] = [:]
    private(set) var queuedFrames = 0
    private(set) var inputEnded = false
    private(set) var isStopped = false
    var isComplete: Bool { !isStopped && inputEnded && pending.isEmpty }

    mutating func schedule(frames: Int) -> Ticket? {
        guard !isStopped, !inputEnded, frames > 0 else { return nil }
        let ticket = Ticket(generation: generation, id: UUID())
        pending[ticket] = frames
        queuedFrames += frames
        return ticket
    }

    @discardableResult
    mutating func played(_ ticket: Ticket) -> Bool {
        guard !isStopped, ticket.generation == generation,
              let frames = pending.removeValue(forKey: ticket) else { return false }
        queuedFrames -= frames
        return true
    }

    mutating func finishInput() { if !isStopped { inputEnded = true } }
    mutating func stop() {
        generation = UUID()
        isStopped = true
        pending.removeAll(keepingCapacity: false)
        queuedFrames = 0
    }
}

/// Only scheduled PCM stays in memory: the caller waits when this two-second
/// queue is full. No downloaded media or decoded audio is written to disk.
@MainActor
final class PCMStreamPlayer {
    static let maximumQueuedFrames = PCMStreamDecoder.sampleRate * 2
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var ledger = PCMPlaybackLedger()
    private var playing = false
    private let onPlaybackChange: (Bool) -> Void
    private let onCompletion: () -> Void

    var queuedFrames: Int { ledger.queuedFrames }
    var isStopped: Bool { ledger.isStopped }

    init(volume: Float = 1, onPlaybackChange: @escaping (Bool) -> Void,
         onCompletion: @escaping () -> Void) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(PCMStreamDecoder.sampleRate), channels: 1) else {
            throw PCMStreamFailure.playbackUnavailable
        }
        self.format = format
        self.onPlaybackChange = onPlaybackChange
        self.onCompletion = onCompletion
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = min(1, max(0, volume))
    }

    func canAccept(frameCount: Int) -> Bool {
        !ledger.isStopped && !ledger.inputEnded && frameCount > 0 &&
        frameCount <= PCMStreamDecoder.chunkFrames &&
        ledger.queuedFrames + frameCount <= Self.maximumQueuedFrames
    }

    func enqueue(_ samples: [Float]) throws {
        guard canAccept(frameCount: samples.count),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw PCMStreamFailure.playbackUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        guard let ticket = ledger.schedule(frames: samples.count) else {
            throw PCMStreamFailure.alreadyFinished
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Stopping an engine inside its audio callback can deadlock.
            Task { @MainActor [weak self] in self?.bufferPlayed(ticket) }
        }
        if !playing {
            node.play()
            setPlaying(true)
        }
    }

    func finishInput() {
        guard !ledger.isStopped else { return }
        ledger.finishInput()
        finishIfDrained()
    }

    func stop() {
        ledger.stop() // Invalidate callbacks before AVFoundation can emit any.
        node.stop()
        engine.stop()
        setPlaying(false)
    }

    private func bufferPlayed(_ ticket: PCMPlaybackLedger.Ticket) {
        guard ledger.played(ticket) else { return }
        if ledger.queuedFrames == 0 {
            node.stop()
            setPlaying(false)
        }
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard ledger.isComplete else { return }
        stop()
        onCompletion()
    }

    private func setPlaying(_ value: Bool) {
        guard playing != value else { return }
        playing = value
        onPlaybackChange(value)
    }
}

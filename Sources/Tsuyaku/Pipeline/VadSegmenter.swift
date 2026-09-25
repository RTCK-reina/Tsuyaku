import Foundation
import FluidAudio

/// One finished (or force-cut) utterance detected by the VAD.
struct Utterance: Sendable {
    var samples: [Float]
    var startSeconds: Double      // relative to pipeline start
    var endSeconds: Double
    var forcedCut: Bool
}

/// Wraps FluidAudio's Silero VAD streaming state machine and slices the audio
/// stream into utterances.
actor VadSegmenter {

    private var vad: VadManager?
    private var streamState: VadStreamState?
    private var segConfig: VadSegmentationConfig
    private(set) var isReady = false

    /// Absolute sample index (16 kHz) of the next incoming sample.
    private var processedSamples: Int = 0

    /// Rolling audio log used to slice utterances; capped (~2 min).
    private var audioLog: [Float] = []
    private var logStartIndex: Int = 0
    private let maxLogSamples = 16000 * 120

    /// Start index of the utterance currently being captured.
    private var utterStart: Int?
    private var pendingForceStart = false

    /// Last observed VAD probability / triggered flag (for the UI meter).
    private(set) var lastProbability: Float = 0
    private(set) var lastTriggered: Bool = false

    /// Hard cap for a single utterance (seconds) — whisper degrades on very long windows.
    private let maxUtteranceSeconds: Double

    init(maxUtteranceSeconds: Double = 12.0,
         segConfig: VadSegmentationConfig = .default) {
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.segConfig = segConfig
    }

    func prepare() async throws {
        if vad == nil {
            var cfg = VadConfig.default
            cfg.computeUnits = .cpuAndNeuralEngine
            vad = try await VadManager(config: cfg)
            streamState = await vad!.makeStreamState()
        }
        isReady = true
    }

    func reset() async {
        if let vad { streamState = await vad.makeStreamState() }
        processedSamples = 0
        audioLog.removeAll(keepingCapacity: true)
        logStartIndex = 0
        utterStart = nil
        pendingForceStart = false
        lastProbability = 0
        lastTriggered = false
    }

    /// Feed a 16 kHz chunk. Returns any completed utterances (usually 0 or 1).
    func submit(_ chunk: [Float]) async throws -> [Utterance] {
        guard let vad, let state = streamState else { return [] }

        audioLog.append(contentsOf: chunk)
        processedSamples += chunk.count
        trimLogIfNeeded()

        var out: [Utterance] = []

        // Force-cut an overly long utterance.
        if let start = utterStart,
           Double(processedSamples - start) / 16000.0 >= maxUtteranceSeconds {
            out.append(makeUtterance(start: start, end: processedSamples, forced: true))
            utterStart = processedSamples
            pendingForceStart = true
        }

        let result = try await vad.processStreamingChunk(chunk, state: state, config: segConfig)
        streamState = result.state
        lastProbability = result.probability
        lastTriggered = result.state.triggered

        if let event = result.event {
            switch event.kind {
            case .speechStart:
                if utterStart == nil || pendingForceStart {
                    utterStart = min(event.sampleIndex, processedSamples)
                    pendingForceStart = false
                }
            case .speechEnd:
                if let start = utterStart {
                    out.append(makeUtterance(start: start,
                                             end: min(event.sampleIndex, processedSamples),
                                             forced: false))
                    utterStart = nil
                    pendingForceStart = false
                }
            }
        }
        return out
    }

    /// Flush any in-flight utterance at stream end.
    func flush() -> Utterance? {
        guard let start = utterStart, processedSamples > start else {
            utterStart = nil
            return nil
        }
        let u = makeUtterance(start: start, end: processedSamples, forced: true)
        utterStart = nil
        return u
    }

    /// Samples for the utterance currently in progress (for partial preview).
    func currentUtteranceSamples() -> [Float]? {
        guard let start = utterStart, processedSamples - start > 8000 else { return nil }
        return slice(from: start, to: processedSamples)
    }

    // MARK: - Helpers

    private func slice(from start: Int, to end: Int) -> [Float] {
        let s = max(0, start - logStartIndex)
        let e = min(audioLog.count, end - logStartIndex)
        guard s < e else { return [] }
        return Array(audioLog[s..<e])
    }

    private func makeUtterance(start: Int, end: Int, forced: Bool) -> Utterance {
        Utterance(
            samples: slice(from: start, to: end),
            startSeconds: Double(start) / 16000.0,
            endSeconds: Double(end) / 16000.0,
            forcedCut: forced
        )
    }

    private func trimLogIfNeeded() {
        let excess = audioLog.count - maxLogSamples
        guard excess > 0 else { return }
        // Never drop samples belonging to the current utterance.
        let keepFrom = utterStart.map { max(0, $0 - 16000) } ?? Int.max
        let drop = min(excess, max(0, keepFrom - logStartIndex))
        if drop > 0 {
            audioLog.removeFirst(drop)
            logStartIndex += drop
        }
    }
}

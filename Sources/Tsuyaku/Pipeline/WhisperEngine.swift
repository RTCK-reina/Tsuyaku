import Foundation
import WhisperKit
import FluidAudio

/// Selectable whisper model variants shown in the UI.
enum WhisperModelChoice: String, CaseIterable, Identifiable, Codable {
    case tiny, base, small, largeTurbo = "large-v3_turbo", large = "large-v3"

    var id: String { rawValue }

    /// Model name inside the argmaxinc/whisperkit-coreml HF repo.
    var kitName: String { "openai_whisper-\(rawValue)" }

    var title: String {
        switch self {
        case .tiny: return "Tiny (~75MB)"
        case .base: return "Base (~145MB)"
        case .small: return "Small (~480MB)"
        case .largeTurbo: return "Large v3 Turbo (~1.6GB)"
        case .large: return "Large v3 (~3GB)"
        }
    }

    var approxSizeMB: Int {
        switch self {
        case .tiny: return 75
        case .base: return 145
        case .small: return 480
        case .largeTurbo: return 1600
        case .large: return 3000
        }
    }
}

struct ASRResult: Sendable {
    var text: String
    var language: String
    var confidence: Float
    var segments: [(start: Float, end: Float, text: String)]
    var inferenceSeconds: Double
    var audioSeconds: Double

    var rtf: Double { audioSeconds > 0 ? inferenceSeconds / audioSeconds : 0 }
}

/// Serializes WhisperKit inference so UI never races the model.
actor WhisperEngine {

    enum State: Sendable {
        case idle, downloading, loading, ready, failed(String)
    }

    private var kit: WhisperKit?
    private(set) var state: State = .idle
    private(set) var loadedChoice: WhisperModelChoice?

    private static var modelsDir: URL { AppSettings.modelsDir }

    /// Is a model's CoreML bundle already on disk?
    static func isDownloaded(_ choice: WhisperModelChoice) -> Bool {
        let dir = modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(choice.kitName)")
        return FileManager.default.fileExists(atPath: dir.path)
    }

    static func downloadedModels() -> [WhisperModelChoice] {
        WhisperModelChoice.allCases.filter(isDownloaded)
    }

    static func deleteModel(_ choice: WhisperModelChoice) {
        let dir = modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(choice.kitName)")
        try? FileManager.default.removeItem(at: dir)
    }

    /// Load (downloading if needed) a model. Safe to call again to switch models.
    func load(_ choice: WhisperModelChoice,
              compute: ModelComputeOptions? = nil,
              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if loadedChoice == choice, kit != nil { return }

        state = Self.isDownloaded(choice) ? .loading : .downloading
        do {
            let config = WhisperKitConfig(
                model: choice.kitName,
                downloadBase: Self.modelsDir,
                modelRepo: "argmaxinc/whisperkit-coreml",
                computeOptions: compute,
                verbose: false,
                logLevel: .error,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            // WhisperKit does not expose download progress through the config; mark ready.
            self.kit = kit
            self.loadedChoice = choice
            state = .ready
            progress?(1.0)
        } catch {
            state = .failed(error.localizedDescription)
            self.kit = nil
            self.loadedChoice = nil
            throw error
        }
    }

    func unload() {
        kit = nil
        loadedChoice = nil
        state = .idle
    }

    /// Transcribe 16 kHz mono samples. Language auto-detection is enabled.
    func transcribe(_ samples: [Float],
                    wordTimestamps: Bool = false,
                    workerCount: Int = 1) async throws -> ASRResult? {
        guard let kit else { return nil }
        guard samples.count > 1600 else { return nil }  // <0.1s: skip

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: wordTimestamps,
            suppressBlank: true,
            concurrentWorkerCount: workerCount,
            chunkingStrategy: .vad
        )

        let start = CFAbsoluteTimeGetCurrent()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        guard let first = results.first else { return nil }
        let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var segs: [(Float, Float, String)] = []
        var logprobSum: Float = 0
        var logprobN = 0
        for r in results {
            for s in r.segments {
                segs.append((Float(s.start), Float(s.end), s.text))
                logprobSum += s.avgLogprob
                logprobN += 1
            }
        }
        let confidence = logprobN > 0 ? expf(logprobSum / Float(logprobN)) : 0
        return ASRResult(
            text: text,
            language: first.language,
            confidence: confidence,
            segments: segs,
            inferenceSeconds: elapsed,
            audioSeconds: Double(samples.count) / 16000.0
        )
    }

    /// Long-form transcription: VAD-segment into utterances, then transcribe each
    /// utterance independently so every utterance gets its own language detection
    /// and correct absolute timestamps. Used by the post-analysis pipeline.
    func transcribeDetailed(_ samples: [Float],
                            workerCount: Int = 4,
                            progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [(start: Float, end: Float, text: String, language: String)] {
        guard kit != nil, !samples.isEmpty else { return [] }

        // 1) Segment into utterances with the same VAD used live.
        var seg = VadSegmentationConfig.default
        seg.minSpeechDuration = 0.2
        seg.minSilenceDuration = 0.5
        seg.speechPadding = 0.15
        let vad = VadSegmenter(maxUtteranceSeconds: 14, segConfig: seg)
        try await vad.prepare()

        var utterances: [Utterance] = []
        let chunkSize = 4096
        var i = 0
        while i < samples.count {
            let end = min(i + chunkSize, samples.count)
            let part = Array(samples[i..<end])
            utterances.append(contentsOf: try await vad.submit(part))
            i = end
        }
        if let tail = await vad.flush() { utterances.append(tail) }

        // 2) Transcribe each utterance.
        var out: [(Float, Float, String, String)] = []
        for (idx, u) in utterances.enumerated() {
            guard let r = try await transcribe(u.samples, workerCount: 1) else { continue }
            let offset = Float(u.startSeconds)
            if r.segments.isEmpty {
                out.append((offset, Float(u.endSeconds), r.text, r.language))
            } else {
                for s in r.segments {
                    let t = s.2.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    out.append((offset + s.0, offset + s.1, t, r.language))
                }
            }
            progress?(idx + 1, utterances.count)
        }
        return out
    }
}

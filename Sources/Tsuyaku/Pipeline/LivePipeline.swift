import Foundation
import FluidAudio

/// One row in the live transcript view.
struct TranscriptItem: Identifiable, Sendable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var speakerLabel: String?
    var language: String
    var languageProb: Float
    var sourceText: String
    var translatedText: String?
    var action: LanguageAction
    var isPartial: Bool
    var rtf: Double

    static func == (a: TranscriptItem, b: TranscriptItem) -> Bool { a.id == b.id }
}

/// Events emitted by the pipeline → AppState.
enum PipelineEvent: Sendable {
    case item(TranscriptItem)              // insert or replace by id
    case partial(TranscriptItem)           // transient preview row
    case vadActive(Bool)
    case vadProb(Float)
    case error(String)
}

/// Orchestrates VAD → ASR → speaker ID → routing → translation.
/// VAD work happens inside `feed`; each utterance is processed on a serial
/// task chain so results stay ordered without blocking audio intake.
actor LivePipeline {

    private var vad: VadSegmenter
    private let whisper: WhisperEngine
    private var speakers: SpeakerTracker
    private var router: LanguageRouter
    private let targetLanguage: String
    private let diarizationOn: Bool
    private let partialsOn: Bool
    private let workerCount: Int

    private var chain: Task<Void, Never>?
    private var lastPartialAt: Date = .distantPast
    private let partialInterval: TimeInterval = 1.6

    /// Translation sink supplied by AppState (MainActor bridge hop).
    private let translate: @Sendable (String, String, String) async -> String?

    let onEvent: @Sendable (PipelineEvent) -> Void

    init(whisper: WhisperEngine,
         router: LanguageRouter,
         maxUtteranceSeconds: Double,
         diarizationOn: Bool,
         partialsOn: Bool,
         workerCount: Int,
         segConfigTuning: (minSpeech: Double, minSilence: Double, padding: Double),
         translate: @escaping @Sendable (String, String, String) async -> String?,
         onEvent: @escaping @Sendable (PipelineEvent) -> Void) {
        self.whisper = whisper
        self.router = router
        self.targetLanguage = router.settings.targetLanguage
        self.diarizationOn = diarizationOn
        self.partialsOn = partialsOn
        self.workerCount = workerCount
        self.translate = translate
        self.onEvent = onEvent

        var seg = VadSegmentationConfig.default
        seg.minSpeechDuration = segConfigTuning.minSpeech
        seg.minSilenceDuration = segConfigTuning.minSilence
        seg.speechPadding = segConfigTuning.padding
        self.vad = VadSegmenter(maxUtteranceSeconds: maxUtteranceSeconds, segConfig: seg)
        self.speakers = SpeakerTracker()
    }

    func prepare() async throws {
        try await vad.prepare()
        if diarizationOn {
            try? await speakers.prepare()  // speaker failure is non-fatal
        }
    }

    func reset() async {
        await vad.reset()
        await speakers.reset()
        chain = nil
        lastPartialAt = .distantPast
    }

    /// Hot path: called for every 0.256 s of audio.
    func feed(_ chunk: [Float]) async {
        do {
            let utterances = try await vad.submit(chunk)
            for u in utterances { enqueue(u) }
            let active = await vad.lastTriggered
            let prob = await vad.lastProbability
            onEvent(.vadActive(active))
            onEvent(.vadProb(prob))
        } catch {
            onEvent(.error("VAD: \(error.localizedDescription)"))
        }

        guard partialsOn else { return }
        if Date().timeIntervalSince(lastPartialAt) > partialInterval,
           let samples = await vad.currentUtteranceSamples() {
            lastPartialAt = Date()
            let whisper = self.whisper
            let onEvent = self.onEvent
            Task {
                if let r = try? await whisper.transcribe(samples, workerCount: 1),
                   !r.text.isEmpty {
                    onEvent(.partial(TranscriptItem(
                        id: UUID(), startSeconds: 0, endSeconds: 0,
                        speakerLabel: nil, language: r.language,
                        languageProb: r.confidence,
                        sourceText: r.text, translatedText: nil,
                        action: .passThrough, isPartial: true, rtf: r.rtf)))
                }
            }
        }
    }

    /// Drain the queue (used on stop / file end).
    func finish() async {
        if let tail = await vad.flush() { enqueue(tail) }
        await chain?.value
    }

    // MARK: - Utterance processing

    private func enqueue(_ u: Utterance) {
        let prev = chain
        chain = Task { [weak self] in
            await prev?.value
            await self?.process(u)
        }
    }

    private func process(_ u: Utterance) async {
        guard !u.samples.isEmpty else { return }

        // 1) ASR
        let asr: ASRResult?
        do {
            asr = try await whisper.transcribe(u.samples, workerCount: workerCount)
        } catch {
            onEvent(.error("ASR: \(error.localizedDescription)"))
            return
        }
        guard let asr, !asr.text.isEmpty else { return }

        let action = router.action(for: asr.language)
        if action == .ignore { return }

        let id = UUID()
        var item = TranscriptItem(
            id: id, startSeconds: u.startSeconds, endSeconds: u.endSeconds,
            speakerLabel: nil, language: asr.language,
            languageProb: asr.confidence,
            sourceText: asr.text, translatedText: nil,
            action: action, isPartial: false, rtf: asr.rtf)
        onEvent(.item(item))

        // 2) Speaker ID (independent of translation)
        if diarizationOn {
            item.speakerLabel = await speakers.identify(samples: u.samples)
        }

        // 3) Translate when the rule says so
        if action == .translate, asr.language != targetLanguage {
            if let t = await translate(asr.text, asr.language, targetLanguage) {
                item.translatedText = t
            }
        }
        onEvent(.item(item))
    }
}

import Foundation
import FluidAudio

/// One merged analysis row: ASR segment + speaker + translation.
struct AnalysisSegment: Identifiable, Sendable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var language: String
    var text: String
    var translation: String?
}

struct SpeakerStat: Sendable, Codable {
    var speaker: String
    var talkSeconds: Double
    var segmentCount: Int
    var share: Double   // 0..1 of total speech
}

struct AnalysisResult: Sendable {
    var fileName: String
    var durationSeconds: Double
    var segments: [AnalysisSegment]
    var speakerStats: [SpeakerStat]
    var languageCounts: [String: Int]
    var summaryMarkdown: String
    var generatedAt: Date

    /// Full markdown export.
    var markdown: String {
        var md = "# \(fileName) — 詳細解析\n\n"
        md += "- 生成: \(generatedAt.formatted())\n"
        md += "- 長さ: \(formatDuration(durationSeconds))\n"
        md += "- 発話数: \(segments.count)\n\n"

        if !speakerStats.isEmpty {
            md += "## 話者統計\n\n"
            for s in speakerStats {
                md += "- \(s.speaker): \(formatDuration(s.talkSeconds)) (\(Int(s.share * 100))%), \(s.segmentCount) 発話\n"
            }
            md += "\n"
        }

        md += "## サマリー\n\n\(summaryMarkdown)\n\n"

        md += "## 全文書き起こし\n\n"
        for seg in segments {
            md += "**[\(formatDuration(seg.start))] \(seg.speaker) (\(LanguageCatalog.name(for: seg.language)))**\n\n"
            md += "\(seg.text)\n\n"
            if let t = seg.translation {
                md += "> \(t)\n\n"
            }
        }
        return md
    }

    var plainText: String {
        segments.map {
            var line = "[\(formatDuration($0.start))] \($0.speaker): \($0.text)"
            if let t = $0.translation { line += "\n    → \(t)" }
            return line
        }.joined(separator: "\n")
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
}

/// Offline pipeline: diarize → transcribe → align speakers → route/translate → summarize.
actor PostAnalysisEngine {

    private let whisper: WhisperEngine
    private let router: LanguageRouter
    private let translate: @Sendable (String, String, String) async -> String?
    private let progress: @Sendable (String) -> Void
    private let maxSpeakers: Int?

    init(whisper: WhisperEngine,
         router: LanguageRouter,
         maxSpeakers: Int? = nil,
         translate: @escaping @Sendable (String, String, String) async -> String?,
         progress: @escaping @Sendable (String) -> Void) {
        self.whisper = whisper
        self.router = router
        self.maxSpeakers = maxSpeakers
        self.translate = translate
        self.progress = progress
    }

    func run(url: URL) async throws -> AnalysisResult {
        // 1) Audio → samples
        progress("音声を読み込み中…")
        let samples = try AudioFileLoader.load(url)
        let duration = Double(samples.count) / 16000.0

        // 2) Offline diarization
        progress("話者分離モデルを準備中…")
        var diarConfig = OfflineDiarizerConfig.default
        if let maxSpeakers { diarConfig.clustering.maxSpeakers = maxSpeakers }
        let diarizer = OfflineDiarizerManager(config: diarConfig)
        try await diarizer.prepareModels()

        progress("話者分離を実行中…")
        let diarResult = try await diarizer.process(
            url,
            progressCallback: { done, total in })
        let speakerSegments = diarResult.segments

        // 3) Full transcription (per-utterance language detection)
        progress("高精度で文字起こし中…")
        let asr = try await whisper.transcribeDetailed(
            samples, workerCount: 4,
            progress: { [progress] done, total in
                progress("文字起こし \(done)/\(total) 発話")
            })

        // 4) Align ASR segments to speakers by max temporal overlap
        progress("話者を割り当て中…")
        var speakerLabels: [String: String] = [:]
        var nextIdx = 0
        func label(for speakerId: String) -> String {
            if let l = speakerLabels[speakerId] { return l }
            let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
            let l = "話者\(chars[min(nextIdx, chars.count - 1)])"
            speakerLabels[speakerId] = l
            nextIdx += 1
            return l
        }

        var merged: [AnalysisSegment] = []
        var langCounts: [String: Int] = [:]
        var speakerTalk: [String: (sec: Double, count: Int)] = [:]

        for seg in asr {
            let spkId = bestSpeaker(for: seg.start...seg.end, in: speakerSegments)
            let spk = spkId.map(label(for:)) ?? "話者?"
            let lang = seg.language
            langCounts[lang, default: 0] += 1

            var translation: String? = nil
            if router.shouldTranslate(lang: lang) {
                translation = await translate(seg.text, lang, router.settings.targetLanguage)
            }

            let dur = Double(seg.end - seg.start)
            var st = speakerTalk[spk] ?? (0, 0)
            st.sec += dur; st.count += 1
            speakerTalk[spk] = st

            merged.append(AnalysisSegment(
                start: Double(seg.start), end: Double(seg.end),
                speaker: spk, language: lang,
                text: seg.text, translation: translation))
        }

        let totalSpeech = speakerTalk.values.reduce(0) { $0 + $1.sec }
        let stats = speakerTalk.map { (k, v) in
            SpeakerStat(speaker: k, talkSeconds: v.sec,
                        segmentCount: v.count,
                        share: totalSpeech > 0 ? v.sec / totalSpeech : 0)
        }.sorted { $0.talkSeconds > $1.talkSeconds }

        // 5) Summary
        progress("サマリーを生成中…")
        let summary = await SummaryEngine.summarize(
            segments: merged, stats: stats, duration: duration)

        return AnalysisResult(
            fileName: url.lastPathComponent,
            durationSeconds: duration,
            segments: merged,
            speakerStats: stats,
            languageCounts: langCounts,
            summaryMarkdown: summary,
            generatedAt: Date())
    }

    // MARK: - Speaker alignment

    private func bestSpeaker(for range: ClosedRange<Float>,
                             in segments: [TimedSpeakerSegment]) -> String? {
        var best: (id: String?, overlap: Float) = (nil, 0)
        for s in segments {
            let overlap = max(0, min(range.upperBound, s.endTimeSeconds)
                              - max(range.lowerBound, s.startTimeSeconds))
            if overlap > best.overlap { best = (s.speakerId, overlap) }
        }
        return best.id
    }
}

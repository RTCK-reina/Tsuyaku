import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates a Japanese summary of an analyzed transcript.
/// Uses Apple's on-device Foundation Models when available (macOS 26+),
/// falling back to a deterministic extractive summary otherwise.
enum SummaryEngine {

    static func summarize(segments: [AnalysisSegment],
                          stats: [SpeakerStat],
                          duration: Double) async -> String {
        let transcript = segments.map {
            "[\(formatDuration($0.start))] \($0.speaker): \($0.text)"
        }.joined(separator: "\n")

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let llm = await llmSummary(transcript: transcript) {
                return llm
            }
        }
        #endif
        return extractive(transcript: transcript, segments: segments,
                          stats: stats, duration: duration)
    }

    // MARK: - On-device LLM

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func llmSummary(transcript: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        // The on-device model has a small context; summarize in chunks of
        // ~3000 chars then synthesize.
        let chunks = transcript.chunked(into: 3000)
        var partials: [String] = []
        let session = LanguageModelSession(
            model: model,
            instructions: """
                あなたは音声書き起こしを分析するアシスタントです。
                出力は必ず日本語の Markdown で、簡潔かつ具体的に書いてください。
                """
        )

        for (i, chunk) in chunks.enumerated() {
            let prompt = """
                以下は会話の書き起こし(部分 \(i + 1)/\(chunks.count))です。
                話題・要点・発言者ごとの主張を箇条書きで要約してください。

                \(chunk)
                """
            if let res = try? await session.respond(to: prompt) {
                partials.append(res.content)
            }
        }
        guard !partials.isEmpty else { return nil }

        let combined = partials.joined(separator: "\n")
        let finalPrompt = """
            以下は書き起こし要約(部分ごと)です。これを統合して、
            1. 「概要」(2-3文)
            2. 「主なポイント」(箇条書き 3-7件)
            3. 「アクションアイテム/決定事項」(あれば、なければ「なし」)
            4. 「話者ごとの傾向」(あれば1行ずつ)
            の形式で出力してください。

            \(combined)
            """
        if let res = try? await session.respond(to: finalPrompt) {
            return res.content
        }
        return combined
    }
    #endif

    // MARK: - Extractive fallback

    private static func extractive(transcript: String,
                                   segments: [AnalysisSegment],
                                   stats: [SpeakerStat],
                                   duration: Double) -> String {
        var md = ""
        let minutes = duration / 60
        md += "**概要**: \(String(format: "%.1f", minutes))分の録音。"
        md += "\(segments.count)発話、\(stats.count)話者を検出。\n\n"

        md += "**主なポイント**:\n"
        // Extractive heuristic: longest segments + frequent content words.
        let longest = segments.sorted { $0.text.count > $1.text.count }.prefix(5)
        for s in longest {
            let t = s.text.count > 80 ? String(s.text.prefix(80)) + "…" : s.text
            md += "- [\(s.speaker)] \(t)\n"
        }

        let keywords = topTerms(in: segments.map(\.text), count: 8)
        if !keywords.isEmpty {
            md += "\n**キーワード**: \(keywords.joined(separator: "、"))\n"
        }

        md += "\n**話者ごとの傾向**:\n"
        for st in stats {
            md += "- \(st.speaker): 発話時間 \(String(format: "%.0f", st.talkSeconds))秒 (\(Int(st.share * 100))%)\n"
        }
        md += "\n(オンデバイスLLMが無効のため抽出式サマリー)"
        return md
    }

    /// Very light keyword extraction: frequent Japanese/English content tokens.
    private static func topTerms(in texts: [String], count: Int) -> [String] {
        var freq: [String: Int] = [:]
        let stop: Set<String> = ["the", "a", "an", "and", "to", "of", "in", "is",
                                 "that", "it", "for", "on", "with", "as", "を",
                                 "に", "は", "が", "の", "と", "です", "ます", "た",
                                 "て", "で", "し", "も", "な", "い", "か", "これ",
                                 "それ", "あれ", "この", "その", "あの", "だ", "です。"]
        for text in texts {
            for word in text.components(separatedBy: CharacterSet.alphanumerics.inverted) {
                let w = word.trimmingCharacters(in: .whitespaces)
                guard w.count >= 3, !stop.contains(w.lowercased()) else { continue }
                freq[w, default: 0] += 1
            }
        }
        return freq.sorted { $0.value > $1.value }.prefix(count).map(\.key)
    }
}

private extension String {
    /// Split into chunks of at most `size` characters at newline boundaries.
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

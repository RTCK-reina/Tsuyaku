import Foundation
import AVFoundation
import WhisperKit
import FluidAudio

// Headless verification harness — mirrors the app's live pipeline:
//   audio → Silero VAD utterances → per-utterance WhisperKit ASR (+ diarization)
// Usage: TsuyakuCLI <audiofile> [modelName] [--diarize] [--whole]

func loadAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: 16000, channels: 1, interleaved: false)!
    guard let inBuf = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "cli", code: 1)
    }
    try file.read(into: inBuf)
    guard inBuf.frameLength > 0 else { return [] }

    if file.processingFormat == target, let p = inBuf.floatChannelData?[0] {
        return Array(UnsafeBufferPointer(start: p, count: Int(inBuf.frameLength)))
    }
    guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw NSError(domain: "cli", code: 2)
    }
    let ratio = target.sampleRate / file.processingFormat.sampleRate
    guard let outBuf = AVAudioPCMBuffer(
        pcmFormat: target,
        frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
    ) else { return [] }
    var consumed = false
    var convErr: NSError?
    conv.convert(to: outBuf, error: &convErr) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true; status.pointee = .haveData; return inBuf
    }
    if let convErr { throw convErr }
    guard let p = outBuf.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
}

/// Minimal copy of the app's VadSegmenter for CLI verification.
final class CliVad {
    private var vad: VadManager?
    private var state: VadStreamState?
    private var log: [Float] = []
    private var logStart = 0
    private var processed = 0
    private var utterStart: Int?
    private var seg = VadSegmentationConfig.default

    struct U { var samples: [Float]; var start: Double; var end: Double }

    init() {
        seg.minSpeechDuration = 0.2
        seg.minSilenceDuration = 0.5
        seg.speechPadding = 0.15
    }

    func prepare() async throws {
        var cfg = VadConfig.default
        cfg.computeUnits = .cpuAndNeuralEngine
        vad = try await VadManager(config: cfg)
        state = await vad!.makeStreamState()
    }

    func submit(_ chunk: [Float]) async throws -> [U] {
        guard let vad, let st = state else { return [] }
        log.append(contentsOf: chunk)
        processed += chunk.count
        var out: [U] = []
        // hard cap 14s
        if let s = utterStart, Double(processed - s) / 16000 >= 14 {
            out.append(slice(s, processed))
            utterStart = processed
        }
        let r = try await vad.processStreamingChunk(chunk, state: st, config: seg)
        state = r.state
        if let e = r.event {
            switch e.kind {
            case .speechStart: if utterStart == nil { utterStart = e.sampleIndex }
            case .speechEnd:
                if let s = utterStart {
                    out.append(slice(s, min(e.sampleIndex, processed)))
                    utterStart = nil
                }
            }
        }
        return out
    }

    func flush() -> U? {
        guard let s = utterStart, processed > s else { return nil }
        utterStart = nil
        return slice(s, processed)
    }

    private func slice(_ s: Int, _ e: Int) -> U {
        let a = max(0, s - logStart), b = min(log.count, e - logStart)
        return U(samples: Array(log[a..<b]),
                 start: Double(s) / 16000, end: Double(e) / 16000)
    }
}

@main
struct CLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: TsuyakuCLI <audio> [model] [--diarize] [--whole]")
            exit(1)
        }
        let url = URL(fileURLWithPath: args[1])
        let model = args.dropFirst(2).first(where: { !$0.hasPrefix("--") }) ?? "openai_whisper-small"
        let doDiarize = args.contains("--diarize")
        let whole = args.contains("--whole")

        do {
            print("== loading audio ==")
            let samples = try loadAudio(url)
            print(String(format: "  %.1fs of audio", Double(samples.count) / 16000))

            print("== loading model \(model) ==")
            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/tsuyaku-models")
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let kit = try await WhisperKit(WhisperKitConfig(
                model: model,
                downloadBase: cacheDir,
                verbose: false, logLevel: .error, download: true))

            var diarSegments: [(Float, Float, String)] = []
            if doDiarize {
                print("== diarizing ==")
                let d = OfflineDiarizerManager()
                try await d.prepareModels()
                let res = try await d.process(url)
                for s in res.segments {
                    diarSegments.append((s.startTimeSeconds, s.endTimeSeconds, s.speakerId))
                    print(String(format: "[%6.1f-%6.1f] %@",
                                 s.startTimeSeconds, s.endTimeSeconds, s.speakerId))
                }
            }

            print("== transcribing ==")
            let opts = DecodingOptions(
                detectLanguage: true, skipSpecialTokens: true,
                chunkingStrategy: .vad)
            let t0 = Date()

            if whole {
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: opts)
                print(String(format: "  inference %.2fs", Date().timeIntervalSince(t0)))
                for r in results {
                    for s in r.segments {
                        print(String(format: "[%6.1f-%6.1f](%@) %@",
                                     s.start, s.end, r.language, s.text))
                    }
                }
            } else {
                // Utterance-based path (same as the app).
                let vad = CliVad()
                try await vad.prepare()
                var utts: [CliVad.U] = []
                var i = 0
                while i < samples.count {
                    let e = min(i + 4096, samples.count)
                    utts.append(contentsOf: try await vad.submit(Array(samples[i..<e])))
                    i = e
                }
                if let tail = await vad.flush() { utts.append(tail) }
                print("  \(utts.count) utterances")

                for u in utts {
                    let rs = try await kit.transcribe(audioArray: u.samples, decodeOptions: opts)
                    for r in rs {
                        for s in r.segments {
                            print(String(format: "[%6.1f-%6.1f](%@) %@",
                                         Float(u.start) + s.start,
                                         Float(u.start) + s.end,
                                         r.language, s.text))
                        }
                    }
                }
                print(String(format: "  total %.2fs", Date().timeIntervalSince(t0)))
            }
        } catch {
            let ns = error as NSError
            print("ERROR: \(ns.domain) \(ns.code) \(ns.localizedDescription) \(ns.userInfo)")
            exit(1)
        }
    }
}

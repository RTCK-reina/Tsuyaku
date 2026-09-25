import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 260, maxWidth: 340)
            analysisPane
                .frame(minWidth: 400)
        }
    }

    // MARK: - Left: session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("録音セッション").font(.headline)
                Spacer()
                Button { state.refreshRecordings() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button { importFile() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("外部ファイルを解析対象に追加")
            }
            .padding(10)

            Divider()

            if state.recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("録音がありません\nライブ中に自動録音されます")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(state.recordings, id: \.wav) { rec in
                    sessionRow(rec)
                }
                .listStyle(.inset)
            }
        }
    }

    private func sessionRow(_ rec: (wav: URL, meta: SessionRecorder.SessionMeta?)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rec.wav.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack {
                if let meta = rec.meta {
                    Text(formatDuration(meta.durationSeconds))
                    Text("·")
                    Text(meta.deviceName)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("詳細解析") { state.analyze(recording: rec.wav) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.analysisInProgress)
                Button("再生") { open(rec.wav) }
                    .controlSize(.small)
                Button("削除", role: .destructive) {
                    delete(rec.wav)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Right: analysis

    private var analysisPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.analysisInProgress {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(state.analysisProgress)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else if let result = state.analysisResult {
                    AnalysisResultView(result: result)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("左のリストから録音を選んで「詳細解析」\n話者分離・高精度書き起こし・サマリーを生成します")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                }
                Spacer()
            }
            .padding(20)
        }
    }

    // MARK: - Actions

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            state.analyze(recording: url)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(
            at: url.deletingPathExtension().appendingPathExtension("json"))
        state.refreshRecordings()
    }
}

struct AnalysisResultView: View {
    let result: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text(result.fileName).font(.title3.weight(.semibold))
                    Text("\(formatDuration(result.durationSeconds)) · \(result.segments.count)発話 · \(result.languageCounts.keys.sorted().map { LanguageCatalog.name(for: $0) }.joined(separator: "/"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Markdownで保存") { export(.markdown) }
                Button("テキストで保存") { export(.plainText) }
            }

            if !result.speakerStats.isEmpty {
                GroupBox("話者統計") {
                    HStack(spacing: 24) {
                        ForEach(result.speakerStats, id: \.speaker) { s in
                            VStack(alignment: .leading) {
                                Text(s.speaker).font(.callout.weight(.semibold))
                                Text("\(formatDuration(s.talkSeconds)) (\(Int(s.share * 100))%)")
                                    .font(.caption)
                                Text("\(s.segmentCount)発話")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            GroupBox("サマリー") {
                Text(LocalizedStringKey(result.summaryMarkdown))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
            }

            GroupBox("書き起こし") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(result.segments) { seg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(seg.speaker)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.15), in: Capsule())
                                Text(LanguageCatalog.name(for: seg.language))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(formatDuration(seg.start))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(seg.text).textSelection(.enabled)
                            if let t = seg.translation {
                                Text(t)
                                    .foregroundStyle(Color.accentColor)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private enum ExportFormat { case markdown, plainText }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .markdown:
            panel.allowedContentTypes = [.init(filenameExtension: "md")!]
            panel.nameFieldStringValue = result.fileName
                .replacingOccurrences(of: ".wav", with: "_analysis.md")
        case .plainText:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = result.fileName
                .replacingOccurrences(of: ".wav", with: "_transcript.txt")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .markdown ? result.markdown : result.plainText
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

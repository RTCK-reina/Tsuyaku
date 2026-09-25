import SwiftUI

struct LiveView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            transcriptArea
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Input source picker
                Picker(selection: inputBinding) {
                    Text("🎙 システムデフォルト").tag(InputSource.device(nil))
                    ForEach(state.inputDevices) { dev in
                        Text(dev.name).tag(InputSource.device(dev))
                    }
                    Divider()
                    Text("🔊 スピーカー出力 (VCの相手側)").tag(InputSource.speaker)
                    Text("🎙🔊 マイク+スピーカー (VC全体)").tag(InputSource.micAndSpeaker)
                    Divider()
                    Text("📄 音声ファイルを選択…").tag(InputSource.file(URL(fileURLWithPath: "__pick__")))
                } label: {
                    Image(systemName: "mic")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .disabled(state.status.isBusy)
                .onChange(of: state.inputSource) { _, src in
                    if case .file(let u) = src, u.lastPathComponent == "__pick__" {
                        pickFile()
                    }
                }

                // Mode toggle
                Picker("", selection: $state.settings.mode) {
                    ForEach(PerformanceMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(state.status.isBusy)

                Spacer()

                // Record toggle
                Button {
                    state.toggleRecording()
                } label: {
                    Label(state.isRecording ? "録音停止" : "録音",
                          systemImage: state.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(state.isRecording ? .red : .secondary)
                .disabled(state.status != .running && !state.isRecording)

                // Start/stop
                Button {
                    state.status.isBusy ? state.stop() : state.start()
                } label: {
                    Label(state.status.isBusy ? "停止" : "開始",
                          systemImage: state.status.isBusy ? "stop.fill" : "play.fill")
                        .frame(width: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.status.isBusy ? .red : .accentColor)
            }

            HStack(spacing: 16) {
                // Level + VAD
                HStack(spacing: 6) {
                    Text("入力").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(state.inputLevel))
                        .frame(width: 80)
                    Circle()
                        .fill(state.isVadActive ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .help("VAD")
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(String(format: "RTF %.2fx", state.lastRTF))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(formatClock(state.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let err = state.lastError ?? state.translationBridge.statusMessage {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    private var statusText: String {
        switch state.status {
        case .idle: return "待機中"
        case .preparing(let m): return m
        case .running:
            return "実行中 — \(state.selectedModel.rawValue) / \(state.settings.mode == .eco ? "eco" : "perf")"
        case .fileMode: return "ファイル処理中…"
        case .failed(let m): return "エラー: \(m)"
        }
    }

    private var inputBinding: Binding<InputSource> {
        Binding(get: { state.inputSource }, set: { state.inputSource = $0 })
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mpeg4Audio, .mp3]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.inputSource = .file(url)
        } else {
            state.inputSource = .device(nil)
        }
    }

    // MARK: - Transcript

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.items) { item in
                        TranscriptRow(item: item)
                            .id(item.id)
                    }
                    if let p = state.partialItem {
                        TranscriptRow(item: p)
                            .opacity(0.5)
                            .id("partial")
                    }
                    if state.items.isEmpty && state.partialItem == nil {
                        emptyState
                    }
                }
                .padding(16)
            }
            .onChange(of: state.items.count) { _, _ in
                withAnimation { proxy.scrollTo(state.items.last?.id, anchor: .bottom) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ear")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(state.status.isBusy
                 ? "音声を待っています…"
                 : "入力デバイスを選んで「開始」を押してください")
                .foregroundStyle(.secondary)
            if state.status.isBusy {
                Text("日本語→スルー / その他→翻訳 (設定で変更可能)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func formatClock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Time
            Text(timeString(item.startSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)

            // Badges
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let spk = item.speakerLabel {
                        badge(spk, color: .purple)
                    }
                    badge(LanguageCatalog.name(for: item.language), color: langColor)
                    if item.action == .ignore { badge("無視", color: .gray) }
                    if item.isPartial { badge("…", color: .gray) }
                }

                Text(item.sourceText)
                    .textSelection(.enabled)
                    .font(.body)

                if let t = item.translatedText {
                    Text(t)
                        .textSelection(.enabled)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else if item.action == .translate && !item.isPartial {
                    Text("翻訳中…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var langColor: Color {
        item.action == .passThrough ? .green : .blue
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

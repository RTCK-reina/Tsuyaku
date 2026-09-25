import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    private var ecoModelBinding: Binding<WhisperModelChoice> {
        Binding(
            get: { WhisperModelChoice(rawValue: state.settings.ecoModel) ?? .base },
            set: { state.settings.ecoModel = $0.rawValue })
    }
    private var perfModelBinding: Binding<WhisperModelChoice> {
        Binding(
            get: { WhisperModelChoice(rawValue: state.settings.performanceModel) ?? .small },
            set: { state.settings.performanceModel = $0.rawValue })
    }

    var body: some View {
        Form {
            Section("動作モード") {
                Picker("モード", selection: $state.settings.mode) {
                    ForEach(PerformanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(modeDescription)
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("話者分離を有効化", isOn: diarizationBinding)
                if !state.settings.diarizationUserOverride {
                    Text("モードに連動 (Eco=オフ / 本気=オン)。手動設定するには切り替えてください。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Toggle("発話中の部分表示 (本気モード)", isOn: $state.settings.partialPreview)
                Toggle("開始時に自動録音", isOn: $state.settings.autoRecord)
            }

            Section("認識モデル (Whisper)") {
                Picker("省電力モード", selection: ecoModelBinding) {
                    ForEach(WhisperModelChoice.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                Picker("本気モード", selection: perfModelBinding) {
                    ForEach(WhisperModelChoice.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                modelManagerRow
            }

            Section("スピーカー入力 (VC対応)") {
                TextField("対象アプリの Bundle ID (カンマ区切り、空=全アプリ)",
                          text: $state.settings.speakerTapBundleIDs)
                    .textFieldStyle(.roundedBorder)
                Text("例: com.hnc.Discord — 入力ソースで「スピーカー出力」または"
                     + "「マイク+スピーカー」を選ぶと有効になります。"
                     + "空欄時は全アプリの音声を取り込みます。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("翻訳") {
                Picker("翻訳先言語", selection: $state.settings.targetLanguage) {
                    ForEach(LanguageCatalog.supported, id: \.code) { l in
                        Text(l.name).tag(l.code)
                    }
                }
                Text("言語ごとの処理 (検出言語 → 動作)")
                    .font(.caption).foregroundStyle(.secondary)
                languageRulesTable
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var modeDescription: String {
        switch state.settings.mode {
        case .eco:
            return "最小リソース: 小型モデル・話者分離オフ・単一スレッド。ゲーム/作業の裏で動かせます。"
        case .performance:
            return "高精度: 大型モデル・話者分離・部分プレビュー・並列処理。"
        }
    }

    private var diarizationBinding: Binding<Bool> {
        Binding(
            get: { state.effectiveDiarization },
            set: { newVal in
                state.settings.diarizationUserOverride = true
                state.settings.diarizationEnabled = newVal
            })
    }

    // MARK: - Models

    private var modelManagerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(WhisperModelChoice.allCases) { m in
                HStack {
                    Text(m.title).font(.callout)
                    Spacer()
                    if state.downloaded.contains(m) {
                        Label("DL済", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                        Button("削除") { state.deleteModel(m) }
                            .font(.caption)
                    } else {
                        Button("ダウンロード") {
                            Task { await state.downloadModel(m) }
                        }
                        .font(.caption)
                    }
                }
            }
            if case .downloading = state.modelState {
                ProgressView(value: state.modelProgress)
                    .progressViewStyle(.linear)
            }
            Text("モデルは Hugging Face (argmaxinc/whisperkit-coreml) から取得し、"
                 + "以後オフラインで動作します。ディスク: ~/Library/Application Support/Tsuyaku/models")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Language rules

    private var languageRulesTable: some View {
        VStack(spacing: 4) {
            HStack {
                Text("言語").frame(width: 110, alignment: .leading)
                Text("動作").frame(width: 140, alignment: .leading)
                Spacer()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(LanguageCatalog.supported, id: \.code) { lang in
                HStack {
                    Text(lang.name).frame(width: 110, alignment: .leading)
                    Picker("", selection: ruleBinding(lang.code)) {
                        ForEach(LanguageAction.allCases) { a in
                            Text(a.title).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    Spacer()
                }
            }
            Divider()
            HStack {
                Text("その他の言語").frame(width: 110, alignment: .leading)
                Picker("", selection: $state.settings.defaultAction) {
                    ForEach(LanguageAction.allCases) { a in
                        Text(a.title).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func ruleBinding(_ code: String) -> Binding<LanguageAction> {
        Binding(
            get: { state.settings.rules[code] ?? state.settings.defaultAction },
            set: { state.settings.rules[code] = $0 })
    }
}

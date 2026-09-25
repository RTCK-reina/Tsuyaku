# Tsuyaku (通訳)

Mac ネイティブの**完全オンデバイス**リアルタイム翻訳アプリ。
ネットワーク通信はモデルの初回ダウンロードのみ。音声は一切外部に送信されません。

## 機能

- **リアルタイム音声認識・翻訳**:マイク/入力デバイスからの音声を VAD で発話分割 → Whisper で認識 → Apple 翻訳フレームワークで翻訳
- **入力デバイス選択**:システムデフォルト / 個別入力デバイス / 音声ファイル(動作確認用)
- **言語フィルタ**:言語ごとに「翻訳 / スルー / 無視」を設定可能(例:日本語=スルー、英語=翻訳→日本語)
- **話者分離**:発話ごとに話者埋め込みを抽出し「話者A/B/C…」を自動ラベリング(本気モード)
- **録音 & 詳細解析**:セッションを WAV 録音 → 後から高精度書き起こし + オフライン話者分離 + 話者統計 + サマリー生成 + Markdown/テキスト書き出し
- **2 モード**:
  - **省電力 (Eco)**: 小型モデル・単発処理・話者分離オフ — ゲーム等と併用向け
  - **本気 (Performance)**: 大型モデル・話者分離・部分プレビュー・並列ワーカー

## 技術構成

| 層 | 技術 |
|---|---|
| UI | SwiftUI (ネイティブ macOS アプリ) |
| 音声入力 | AVAudioEngine (デバイス個別指定可) → 16kHz mono |
| VAD | FluidAudio (Silero VAD / CoreML・ANE) |
| ASR | WhisperKit (whisper CoreML / ANE) |
| 話者分離 | FluidAudio (pyannote CoreML) — ライブは発話単位埋め込み一致、解析はオフライン VBx クラスタリング |
| 翻訳 | Apple Translation framework (オンデバイス) |
| サマリー | Apple Foundation Models (macOS 26+) + 抽出式フォールバック |

## ビルド & 起動

```bash
# .app バンドル作成 (release ビルド + Info.plist + ad-hoc 署名)
./Scripts/make_app.sh
open dist/Tsuyaku.app
```

または直接:

```bash
swift run -c release Tsuyaku
```

CLI 検証ハーネス:

```bash
swift run TsuyakuCLI <audio.wav> [model] [--diarize] [--whole]
```

## 初回セットアップ

1. 起動 → 設定タブ → 使うモデルをダウンロード (Eco=base 推奨 / 本気=small 推奨)
2. 翻訳言語ペアは初回翻訳時に macOS が言語パックの DL を促すことがあります
   (システム設定 → 一般 → 言語と地域 → 翻訳言語 でも事前 DL 可能)
3. マイク権限を許可

## ファイル配置

- 設定: `~/Library/Application Support/Tsuyaku/settings.json`
- モデル: `~/Library/Application Support/Tsuyaku/models`
- 録音: `~/Library/Application Support/Tsuyaku/recordings`

## 既知の制約

- 翻訳は Apple Translation の対応言語ペアに依存 (日英など主要ペアは OK)
- 話者分離のライブラベリングは発話単位の簡易一致。正確な分離は「詳細解析」側で
- macOS 15+ 必須 (サマリー LLM は macOS 26+)

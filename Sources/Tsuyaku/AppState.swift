import Foundation
import SwiftUI
import Combine
import CoreAudio

enum PipelineStatus: Equatable {
    case idle
    case preparing(String)
    case running
    case fileMode
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
    var isBusy: Bool {
        if case .preparing = self { return true }
        return self == .running || self == .fileMode
    }
}

enum InputSource: Hashable, Identifiable {
    case device(AudioDeviceManager.InputDevice?)
    case file(URL)
    /// Speaker output only — captures the remote side of voice chat.
    case speaker
    /// Microphone + speaker output stacked — full voice-chat capture.
    case micAndSpeaker

    var id: String {
        switch self {
        case .device(let d): return "dev:\(d?.uid ?? "default")"
        case .file(let u): return "file:\(u.lastPathComponent)"
        case .speaker: return "speaker"
        case .micAndSpeaker: return "mic+speaker"
        }
    }
    var displayName: String {
        switch self {
        case .device(let d): return d?.name ?? "システムデフォルト"
        case .file(let u): return "📄 \(u.lastPathComponent)"
        case .speaker: return "🔊 スピーカー出力"
        case .micAndSpeaker: return "🎙🔊 マイク+スピーカー"
        }
    }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: Settings
    @Published var settings: AppSettings { didSet { settings.save() } }

    // MARK: Devices & input
    @Published var inputDevices: [AudioDeviceManager.InputDevice] = []
    @Published var inputSource: InputSource = .device(nil)

    // MARK: Pipeline
    @Published var status: PipelineStatus = .idle
    @Published var items: [TranscriptItem] = []
    @Published var partialItem: TranscriptItem?
    @Published var inputLevel: Float = 0
    @Published var isVadActive = false
    @Published var lastError: String?

    // MARK: Model
    @Published var modelState: WhisperEngine.State = .idle
    @Published var modelProgress: Double = 0
    @Published var downloaded: Set<WhisperModelChoice> = []

    // MARK: Recording
    @Published var isRecording = false
    @Published var recordings: [(wav: URL, meta: SessionRecorder.SessionMeta?)] = []

    // MARK: Stats
    @Published var elapsed: TimeInterval = 0
    @Published var lastRTF: Double = 0
    @Published var vadProbability: Float = 0

    // MARK: Translation
    let translationBridge = TranslationBridge()

    // MARK: Analysis
    @Published var analysisInProgress = false
    @Published var analysisProgress: String = ""
    @Published var analysisResult: AnalysisResult?
    @Published var analysisFileURL: URL?

    // MARK: UI state
    @Published var selectedTab = 0

    // MARK: Internals
    private let capture = AudioCaptureEngine()
    private let tapCapture = TapCaptureEngine()
    private let speakerTap = SpeakerTap()
    private let recorder = SessionRecorder()
    private var pipeline: LivePipeline?
    private var whisper = WhisperEngine()
    private var timer: Timer?
    private var fileFeedTask: Task<Void, Never>?
    private var itemIndex: [UUID: Int] = [:]
    private let maxItems = 400
    /// Bumped on every start/stop; stale async startups check it and bail out.
    private var generation = 0

    var selectedModel: WhisperModelChoice {
        WhisperModelChoice(rawValue:
            settings.mode == .eco ? settings.ecoModel : settings.performanceModel
        ) ?? .base
    }

    /// Item-level diagnostic logging is enabled by any test hook.
    static var testLoggingEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TSUYAKU_TEST_FILE"] != nil || env["TSUYAKU_TEST_LIVE"] != nil
    }

    static func tlog(_ msg: String) {
        FileHandle.standardError.write("\(msg)\n".data(using: .utf8)!)
    }

    init() {
        settings = AppSettings.load()
        refreshDevices()
        refreshRecordings()
        refreshDownloaded()

        let env = ProcessInfo.processInfo.environment

        // Verification hook: dump enumerated input devices to stderr.
        if env["TSUYAKU_LIST_DEVICES"] != nil {
            for d in inputDevices {
                Self.tlog("[device] id=\(d.id) uid=\(d.uid) rate=\(d.sampleRate) name=\(d.name)")
            }
        }

        // Headless E2E hook: TSUYAKU_TEST_FILE=/path/to.wav starts file mode.
        if let testFile = env["TSUYAKU_TEST_FILE"] {
            inputSource = .file(URL(fileURLWithPath: testFile))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.start()
            }
        // Live-capture hook: TSUYAKU_TEST_LIVE=1 uses the system default input.
        } else if let liveMode = env["TSUYAKU_TEST_LIVE"] {
            switch liveMode {
            case "speaker": inputSource = .speaker
            case "mic+speaker": inputSource = .micAndSpeaker
            default: inputSource = .device(nil)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.start()
                while true {
                    try? await Task.sleep(for: .seconds(3))
                    Self.tlog("[live] status=\(self.status) level=\(String(format: "%.3f", self.inputLevel)) vad=\(String(format: "%.2f", self.vadProbability)) items=\(self.items.count) rec=\(self.isRecording)")
                }
            }
        // Analysis hook: TSUYAKU_TEST_ANALYZE=/path/to.wav runs post-analysis
        // and dumps the resulting markdown to stderr.
        } else if let analyzePath = env["TSUYAKU_TEST_ANALYZE"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.analyze(recording: URL(fileURLWithPath: analyzePath))
                while self.analysisInProgress {
                    try? await Task.sleep(for: .seconds(2))
                    Self.tlog("[analysis] \(self.analysisProgress)")
                }
                if let r = self.analysisResult {
                    Self.tlog("[analysis-result]\n\(r.markdown)")
                } else {
                    Self.tlog("[analysis-failed] \(self.analysisProgress)")
                }
            }
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        inputDevices = AudioDeviceManager.inputDevices()
        if case .device(let current) = inputSource,
           let uid = current?.uid,
           !inputDevices.contains(where: { $0.uid == uid }) {
            inputSource = .device(nil)
        }
    }

    func refreshDownloaded() {
        downloaded = Set(WhisperEngine.downloadedModels())
    }

    func refreshRecordings() {
        recordings = SessionRecorder.listSessions()
    }

    // MARK: - Model management

    /// Load the model the current mode requires; no-ops when already loaded.
    func ensureModel() async throws {
        let choice = selectedModel
        if case .ready = modelState, await whisper.loadedChoice == choice { return }
        try await whisper.load(choice) { [weak self] p in
            Task { @MainActor in self?.modelProgress = p }
        }
        modelState = await whisper.state
        refreshDownloaded()
    }

    func downloadModel(_ choice: WhisperModelChoice) async {
        do {
            try await whisper.load(choice) { [weak self] p in
                Task { @MainActor in self?.modelProgress = p }
            }
            modelState = await whisper.state
        } catch {
            modelState = .failed(error.localizedDescription)
        }
        refreshDownloaded()
    }

    func deleteModel(_ choice: WhisperModelChoice) {
        WhisperEngine.deleteModel(choice)
        refreshDownloaded()
    }

    // MARK: - Start / Stop

    func start() {
        guard !status.isBusy else { return }
        items.removeAll(); itemIndex.removeAll()
        partialItem = nil
        lastError = nil
        elapsed = 0

        let mode = settings.mode
        let maxUtt: Double = mode == .eco ? 10.0 : 14.0
        let workers = mode == .eco ? 1 : 4
        let diarOn = effectiveDiarization
        let partials = mode == .performance && settings.partialPreview

        status = .preparing("モデルを読み込み中…")
        generation += 1
        let gen = generation

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureModel()
                guard case .ready = self.modelState else {
                    if case .failed(let m) = self.modelState { self.status = .failed(m) }
                    else { self.status = .failed("モデルを読み込めませんでした") }
                    return
                }

                self.status = .preparing("VAD/話者分離を準備中…")
                let router = LanguageRouter(settings: self.settings)
                let bridge = self.translationBridge
                let pipeline = LivePipeline(
                    whisper: self.whisper,
                    router: router,
                    maxUtteranceSeconds: maxUtt,
                    diarizationOn: diarOn,
                    partialsOn: partials,
                    workerCount: workers,
                    segConfigTuning: (
                        minSpeech: 0.2,
                        minSilence: mode == .eco ? 0.6 : 0.45,
                        padding: 0.15
                    ),
                    translate: { text, source, target in
                        await bridge.translate(text, source: source, target: target)
                    },
                    onEvent: { [weak self] ev in
                        Task { @MainActor in self?.handle(ev) }
                    })
                try await pipeline.prepare()
                guard self.generation == gen else {
                    await pipeline.reset()
                    return
                }
                self.pipeline = pipeline

                switch self.inputSource {
                case .device(let dev):
                    try self.startCapture(deviceID: dev?.id)
                    self.status = .running
                    if self.settings.autoRecord { self.toggleRecording(force: true) }
                case .speaker:
                    try self.startSpeakerCapture(includeMic: false)
                    self.status = .running
                    if self.settings.autoRecord { self.toggleRecording(force: true) }
                case .micAndSpeaker:
                    try self.startSpeakerCapture(includeMic: true)
                    self.status = .running
                    if self.settings.autoRecord { self.toggleRecording(force: true) }
                case .file(let url):
                    self.status = .fileMode
                    if self.settings.autoRecord { self.toggleRecording(force: true) }
                    self.startFileFeed(url: url)
                }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        fileFeedTask?.cancel()
        fileFeedTask = nil
        capture.stop()
        tapCapture.stop()
        speakerTap.stop()
        if isRecording { toggleRecording(force: false) }
        let p = pipeline
        pipeline = nil
        Task {
            await p?.finish()
            await p?.reset()
        }
        status = .idle
        partialItem = nil
        inputLevel = 0
        isVadActive = false
        timer?.invalidate()
        timer = nil
        generation += 1
    }

    private func attachCaptureCallbacks() {
        let onChunk: ([Float]) -> Void = { [weak self] chunk in
            self?.recorder.write(samples: chunk)
            Task { @MainActor [weak self] in
                await self?.pipeline?.feed(chunk)
            }
        }
        let onLevel: (Float) -> Void = { [weak self] lvl in
            Task { @MainActor in self?.inputLevel = lvl }
        }
        capture.onAudioChunk = onChunk
        capture.onLevel = onLevel
        tapCapture.onAudioChunk = onChunk
        tapCapture.onLevel = onLevel
    }

    private func startCapture(deviceID: AudioDeviceID?) throws {
        attachCaptureCallbacks()
        try capture.start(deviceID: deviceID)
        startTimer()
    }

    /// Speaker-output capture via a CoreAudio process tap (VC support).
    /// includeMic stacks the default mic into the same aggregate device.
    private func startSpeakerCapture(includeMic: Bool) throws {
        var micUID: String? = nil
        if includeMic {
            guard let micID = AudioDeviceManager.defaultInputDeviceID(),
                  let uid = AudioDeviceManager.deviceUID(forID: micID)
            else { throw SpeakerTap.TapError.micUnavailable }
            micUID = uid
        }
        let ids = settings.speakerTapBundleIDs
            .split(separator: ",").map(String.init)
        let deviceID = try speakerTap.start(includeMicUID: micUID, bundleIDs: ids)
        attachCaptureCallbacks()
        try tapCapture.start(deviceID: deviceID)
        startTimer()
    }

    /// Feed an audio file through the pipeline as fast as the queue drains.
    private func startFileFeed(url: URL) {
        fileFeedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let samples = try await Task.detached {
                    try AudioFileLoader.load(url)
                }.value

                let chunkSize = 4096
                var i = 0
                while i < samples.count && !Task.isCancelled {
                    let end = min(i + chunkSize, samples.count)
                    let chunk = Array(samples[i..<end])
                    if self.isRecording { self.recorder.write(samples: chunk) }
                    await self.pipeline?.feed(chunk)
                    self.inputLevel = min(1, (chunk.map(abs).max() ?? 0) * 1.5)
                    self.elapsed = Double(i) / 16000.0
                    i = end
                }
                await self.pipeline?.finish()
                if !Task.isCancelled {
                    self.status = .idle
                    if self.isRecording { self.toggleRecording(force: false) }
                }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
    }

    // MARK: - Recording

    func toggleRecording(force: Bool? = nil) {
        let want = force ?? !isRecording
        if want == isRecording { return }
        if want {
            do {
                _ = try recorder.start(deviceName: inputSource.displayName,
                                       mode: settings.mode)
                isRecording = true
            } catch {
                lastError = "録音開始に失敗: \(error.localizedDescription)"
            }
        } else {
            _ = recorder.stop()
            isRecording = false
            refreshRecordings()
        }
    }

    // MARK: - Events

    private func handle(_ ev: PipelineEvent) {
        switch ev {
        case .item(let item):
            lastRTF = item.rtf
            if Self.testLoggingEnabled {
                Self.tlog("[item] \(item.speakerLabel ?? "-") |\(item.language)| \(item.sourceText) => \(item.translatedText ?? "-")")
            }
            if let idx = itemIndex[item.id] {
                items[idx] = item
            } else {
                itemIndex[item.id] = items.count
                items.append(item)
                if items.count > maxItems {
                    items.removeFirst()
                    itemIndex = Dictionary(uniqueKeysWithValues:
                        items.enumerated().map { ($0.element.id, $0.offset) })
                }
            }
        case .partial(let item):
            partialItem = item
        case .vadActive(let a):
            isVadActive = a
        case .vadProb(let p):
            vadProbability = p
        case .error(let msg):
            lastError = msg
        }
    }

    // MARK: - Analysis

    func analyze(recording wav: URL) {
        guard !analysisInProgress else { return }
        analysisInProgress = true
        analysisProgress = "解析を準備中…"
        analysisResult = nil
        analysisFileURL = wav

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureModel()
            } catch {
                self.analysisProgress = "モデル読み込み失敗: \(error.localizedDescription)"
                self.analysisInProgress = false
                return
            }
            let engine = PostAnalysisEngine(
                whisper: self.whisper,
                router: LanguageRouter(settings: self.settings),
                translate: { [bridge = self.translationBridge] text, source, target in
                    await bridge.translate(text, source: source, target: target)
                },
                progress: { [weak self] msg in
                    Task { @MainActor in self?.analysisProgress = msg }
                })
            do {
                let result = try await engine.run(url: wav)
                self.analysisResult = result
            } catch {
                self.analysisProgress = "解析失敗: \(error.localizedDescription)"
            }
            self.analysisInProgress = false
        }
    }

    var effectiveDiarization: Bool {
        settings.diarizationUserOverride ? settings.diarizationEnabled
                                       : (settings.mode == .performance)
    }
}

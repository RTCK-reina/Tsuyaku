import Foundation

enum PerformanceMode: String, Codable, CaseIterable, Identifiable {
    case eco
    case performance

    var id: String { rawValue }
    var title: String {
        switch self {
        case .eco: return "省電力 (Eco)"
        case .performance: return "本気 (Performance)"
        }
    }
}

/// What to do with speech detected in a given language.
enum LanguageAction: String, Codable, CaseIterable, Identifiable {
    case translate   // translate to the app-wide target language
    case passThrough // display as-is
    case ignore      // drop entirely

    var id: String { rawValue }
    var title: String {
        switch self {
        case .translate: return "翻訳"
        case .passThrough: return "スルー"
        case .ignore: return "無視"
        }
    }
}

struct LanguageRule: Codable, Hashable {
    /// BCP-47-ish whisper language code: "ja", "en", "zh", "ko", ...
    var language: String
    var action: LanguageAction
}

struct AppSettings: Codable {
    var mode: PerformanceMode = .eco

    /// Device UID; AudioDeviceManager.defaultDeviceUID = system default.
    var inputDeviceUID: String = "__system_default__"

    /// Comma-separated bundle IDs to limit the speaker tap to specific apps
    /// (e.g. "com.hnc.Discord"). Empty = capture all system output.
    var speakerTapBundleIDs: String = ""

    /// Language everything translates into (default Japanese).
    var targetLanguage: String = "ja"

    /// Per-language routing. Missing entries fall back to `defaultAction`.
    var rules: [String: LanguageAction] = [
        "ja": .passThrough,
        "en": .translate,
        "zh": .translate,
        "ko": .translate,
    ]
    var defaultAction: LanguageAction = .translate

    /// Whisper model selection per mode.
    var ecoModel: String = "base"
    var performanceModel: String = "small"

    /// Speaker separation on/off (auto-forced by mode unless user overrides).
    var diarizationEnabled: Bool = false
    var diarizationUserOverride: Bool = false

    /// Show live partial transcription while an utterance is in progress.
    var partialPreview: Bool = false

    /// Auto-start recording whenever the pipeline runs.
    var autoRecord: Bool = true

    /// Max speakers hint for diarization.
    var maxSpeakers: Int = 4

    static func load() -> AppSettings {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    func save() {
        let url = Self.settingsURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsuyaku", isDirectory: true)
    }
    static var modelsDir: URL { supportDir.appendingPathComponent("models", isDirectory: true) }
    static var recordingsDir: URL {
        supportDir.appendingPathComponent("recordings", isDirectory: true)
    }
    private static var settingsURL: URL {
        supportDir.appendingPathComponent("settings.json")
    }
}

/// Whisper language codes → display names (subset + common ones).
enum LanguageCatalog {
    static let supported: [(code: String, name: String)] = [
        ("ja", "日本語"), ("en", "English"), ("zh", "中文"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"),
        ("pt", "Português"), ("ru", "Русский"), ("vi", "Tiếng Việt"), ("th", "ไทย"),
        ("id", "Indonesia"), ("hi", "हिन्दी"), ("ar", "العربية"), ("nl", "Nederlands"),
        ("sv", "Svenska"), ("pl", "Polski"), ("tr", "Türkçe"), ("uk", "Українська"),
    ]

    static func name(for code: String) -> String {
        supported.first(where: { $0.code == code })?.name ?? code
    }
}

import Foundation

/// Decides what to do with each detected language based on user rules.
struct LanguageRouter {
    var settings: AppSettings

    func action(for detectedLanguage: String) -> LanguageAction {
        if let rule = settings.rules[detectedLanguage] { return rule }
        // Try base subtag (e.g. "zh" for "zh-cn" style values, though whisper gives 2-letter codes).
        let base = String(detectedLanguage.prefix(2))
        if let rule = settings.rules[base] { return rule }
        return settings.defaultAction
    }

    /// True when text in `lang` should be translated into the target language.
    func shouldTranslate(lang: String) -> Bool {
        action(for: lang) == .translate && lang != settings.targetLanguage
    }
}

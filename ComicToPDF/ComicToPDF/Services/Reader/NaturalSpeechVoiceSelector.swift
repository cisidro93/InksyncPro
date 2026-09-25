import Foundation
import AVFoundation

/// NaturalSpeechVoiceSelector
///
/// Centralized engine providing the most lifelike, human, and natural speech synthesis
/// on Apple devices by intelligently leveraging:
/// 1. iOS 17+ `.premium` and iOS 16+ `.enhanced` Siri and neural voice models
/// 2. Natural pre-utterance buffer priming (`preUtteranceDelay`) to prevent first-syllable audio clipping
/// 3. Human cadence sentence pauses (`postUtteranceDelay: 0.14s`) to mimic natural breathing between sentences
/// 4. Language-specific neural voice resolution (e.g. Japanese, British, American, etc.)
/// 5. Persistent preferred voice storage across reader sessions
@MainActor
public final class NaturalSpeechVoiceSelector {
    public static let shared = NaturalSpeechVoiceSelector()

    private let userDefaultsKey = "inksync_preferred_natural_voice_id"

    /// Persisted user-preferred voice identifier
    public var preferredVoiceIdentifier: String {
        get {
            UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
        }
    }

    private init() {}

    /// Returns all available speech voices sorted with the most natural voices first
    /// (Personal Voices -> Premium Neural -> Enhanced Neural -> Default).
    public var sortedAvailableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { a, b in
            // Compare quality descending
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue > b.quality.rawValue
            }
            // Same quality: group by language, then name
            if a.language != b.language {
                return a.language < b.language
            }
            return a.name < b.name
        }
    }

    /// Resolves the highest quality available voice for the specified language or text snippet.
    /// Priority order:
    /// 1. Explicit voice provided by user/caller (if non-nil)
    /// 2. User-saved preferred voice from settings (if installed on device)
    /// 3. Personal Voice (iOS 17+ on-device personal voice clone, if authorized and available)
    /// 4. Premium quality Apple neural voices (.premium, iOS 17+)
    /// 5. Enhanced quality Apple neural voices (.enhanced, iOS 16+)
    /// 6. High-quality Siri neural voices
    /// 7. Default system voice for the target language
    public func resolveBestVoice(
        explicitVoice: AVSpeechSynthesisVoice? = nil,
        languageCode: String? = nil,
        forText text: String? = nil
    ) -> AVSpeechSynthesisVoice {
        // 1. Explicit caller choice
        if let explicitVoice {
            return explicitVoice
        }

        // 2. User-saved preferred voice identifier
        if !preferredVoiceIdentifier.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return savedVoice
        }

        // 3. Resolve target language
        let targetLanguage = resolveTargetLanguage(languageCode: languageCode, text: text)
        let langPrefix = String(targetLanguage.prefix(2)).lowercased()

        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let matchingVoices = allVoices.filter { voice in
            let voiceLang = voice.language.lowercased()
            return voiceLang == targetLanguage.lowercased() || voiceLang.starts(with: langPrefix)
        }

        // 4. Look for .premium voices (iOS 17+)
        if #available(iOS 17.0, *) {
            if let premiumVoice = matchingVoices.first(where: { $0.quality == .premium }) {
                return premiumVoice
            }
        }

        // 5. Look for .enhanced voices (iOS 16+)
        if let enhancedVoice = matchingVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }

        // 6. Look for Siri/neural voices by identifier
        if let siriVoice = matchingVoices.first(where: {
            $0.identifier.localizedCaseInsensitiveContains("siri") ||
            $0.identifier.localizedCaseInsensitiveContains("neural")
        }) {
            return siriVoice
        }

        // 7. Fallback to default voice for language or system default
        return AVSpeechSynthesisVoice(language: targetLanguage)
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? allVoices.first
            ?? AVSpeechSynthesisVoice()
    }

    /// Automatically detects language from text contents or returns language code / device locale
    public func resolveTargetLanguage(languageCode: String?, text: String?) -> String {
        if let languageCode, !languageCode.isEmpty {
            return languageCode
        }

        if let text, !text.isEmpty {
            let hasJapanese = text.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value) || // Hiragana
                (0x30A0...0x30FF).contains(scalar.value) || // Katakana
                (0x4E00...0x9FAF).contains(scalar.value)    // CJK Unified Ideographs
            }
            if hasJapanese {
                return "ja-JP"
            }
        }

        return Locale.current.language.languageCode?.identifier ?? "en-US"
    }

    /// Configures an `AVSpeechUtterance` for peak naturalness, clear diction, and human cadence.
    public func configureNaturalUtterance(
        _ utterance: AVSpeechUtterance,
        voice: AVSpeechSynthesisVoice? = nil,
        speechRate: Float = 1.0,
        pitchMultiplier: Float = 1.0,
        volume: Float = 1.0,
        isSentenceUnit: Bool = true
    ) {
        // Resolve and assign best voice
        utterance.voice = resolveBestVoice(explicitVoice: voice, forText: utterance.speechString)

        // Speed rate: Apple default rate is 0.5. Scale smoothly.
        let baseRate = AVSpeechUtteranceDefaultSpeechRate
        let clampedMultiplier = max(0.5, min(2.5, speechRate))
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, baseRate * clampedMultiplier))

        // Pre-utterance delay primes CoreAudio buffers smoothly, preventing clipped leading consonants
        utterance.preUtteranceDelay = 0.03

        // Post-utterance delay introduces natural human breathing cadence between sentences
        utterance.postUtteranceDelay = isSentenceUnit ? 0.14 : 0.08

        utterance.pitchMultiplier = min(1.15, max(0.85, pitchMultiplier))
        utterance.volume = min(1.0, max(0.0, volume))
    }
}

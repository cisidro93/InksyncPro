import Foundation
import AVFoundation
import NaturalLanguage

/// NaturalSpeechCadence
/// Defines natural breathing pauses between sentences and paragraphs to eliminate robotic cadence.
public enum NaturalSpeechCadence: String, CaseIterable, Identifiable, Sendable {
    case natural = "Natural"
    case brisk = "Brisk"
    case relaxed = "Relaxed"

    public var id: String { rawValue }

    public var sentenceDelay: TimeInterval {
        switch self {
        case .natural: return 0.16
        case .brisk: return 0.08
        case .relaxed: return 0.26
        }
    }

    public var paragraphDelay: TimeInterval {
        switch self {
        case .natural: return 0.32
        case .brisk: return 0.16
        case .relaxed: return 0.48
        }
    }

    public var description: String {
        switch self {
        case .natural: return "Balanced human breathing pauses (recommended)"
        case .brisk: return "Shorter pauses for accelerated comprehension"
        case .relaxed: return "Gentle, deliberate pacing for deep study"
        }
    }
}

/// NaturalSpeechVoiceSelector
///
/// Centralized engine providing the most lifelike, human, and natural speech synthesis
/// on Apple devices by intelligently leveraging:
/// 1. iOS 17+ `.premium` and iOS 16+ `.enhanced` Siri and neural voice models
/// 2. Natural pre-utterance buffer priming (`preUtteranceDelay`) to prevent first-syllable audio clipping
/// 3. Human cadence sentence pauses (`postUtteranceDelay`) to mimic natural breathing between sentences
/// 4. Apple NaturalLanguage (`NLLanguageRecognizer`) for instant on-device text language recognition
/// 5. Apple Personal Voice authorization and prioritization
/// 6. Persistent preferred voice storage across reader sessions
@MainActor
public final class NaturalSpeechVoiceSelector: ObservableObject {
    public static let shared = NaturalSpeechVoiceSelector()

    private let voiceIdKey = "inksync_preferred_natural_voice_id"
    private let cadenceKey = "inksync_speech_cadence_mode"
    private let autoLangKey = "inksync_speech_auto_detect_language"

    /// Persisted user-preferred voice identifier
    public var preferredVoiceIdentifier: String {
        get {
            UserDefaults.standard.string(forKey: voiceIdKey) ?? ""
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: voiceIdKey)
        }
    }

    /// User-selected breathing cadence mode
    public var cadenceMode: NaturalSpeechCadence {
        get {
            guard let raw = UserDefaults.standard.string(forKey: cadenceKey),
                  let cadence = NaturalSpeechCadence(rawValue: raw) else {
                return .natural
            }
            return cadence
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: cadenceKey)
        }
    }

    /// Whether to auto-detect language of book passages using Apple NaturalLanguage
    public var isAutoDetectLanguageEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoLangKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoLangKey)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: autoLangKey)
        }
    }

    /// Indicates whether the current device has downloaded any Apple .premium or .enhanced neural voices
    public var hasHighQualityNeuralVoiceInstalled: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { voice in
            if #available(iOS 17.0, *) {
                if voice.quality == .premium { return true }
            }
            return voice.quality == .enhanced
        }
    }

    private init() {}

    /// Returns all available speech voices sorted with the most natural voices first
    /// (Personal Voices -> Premium Neural -> Enhanced Neural -> Default).
    public var sortedAvailableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { a, b in
            // 1. Personal Voices first (iOS 17+)
            if #available(iOS 17.0, *) {
                let aPersonal = a.voiceTraits.contains(.isPersonalVoice)
                let bPersonal = b.voiceTraits.contains(.isPersonalVoice)
                if aPersonal != bPersonal {
                    return aPersonal
                }
            }

            // 2. Compare quality descending (.premium > .enhanced > .default)
            if a.quality.rawValue != b.quality.rawValue {
                return a.quality.rawValue > b.quality.rawValue
            }

            // 3. For English voices of the same quality, prioritize Apple's flagship studio voices
            let preferredNames = ["Ava", "Zoe", "Evan", "Nathan", "Alex", "Samantha", "Serena", "Oliver"]
            let aRank = preferredNames.firstIndex(of: a.name) ?? 999
            let bRank = preferredNames.firstIndex(of: b.name) ?? 999
            if aRank != bRank {
                return aRank < bRank
            }

            // 4. Group by language, then name
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
    /// 4. Flagship Apple neural voices (.premium, iOS 17+)
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

        // 3. Check for Personal Voice if authorized (iOS 17+)
        if #available(iOS 17.0, *) {
            if AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized {
                let personalVoices = AVSpeechSynthesisVoice.speechVoices().filter {
                    $0.voiceTraits.contains(.isPersonalVoice)
                }
                if let firstPersonal = personalVoices.first {
                    return firstPersonal
                }
            }
        }

        // 4. Resolve target language
        let targetLanguage = resolveTargetLanguage(languageCode: languageCode, text: text)
        let langPrefix = String(targetLanguage.prefix(2)).lowercased()

        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let matchingVoices = allVoices.filter { voice in
            let voiceLang = voice.language.lowercased()
            return voiceLang == targetLanguage.lowercased() || voiceLang.starts(with: langPrefix)
        }

        // 5. Look for flagship .premium voices (iOS 17+)
        if #available(iOS 17.0, *) {
            let premiumVoices = matchingVoices.filter { $0.quality == .premium }
            if !premiumVoices.isEmpty {
                // Check for flagship voices first
                let flagshipNames = ["Ava", "Zoe", "Evan", "Nathan"]
                if let flagship = premiumVoices.first(where: { flagshipNames.contains($0.name) }) {
                    return flagship
                }
                if let firstPremium = premiumVoices.first {
                    return firstPremium
                }
            }
        }

        // 6. Look for .enhanced voices (iOS 16+)
        let enhancedVoices = matchingVoices.filter { $0.quality == .enhanced }
        if !enhancedVoices.isEmpty {
            let flagshipEnhanced = ["Ava", "Samantha", "Serena", "Oliver", "Daniel"]
            if let flagship = enhancedVoices.first(where: { flagshipEnhanced.contains($0.name) }) {
                return flagship
            }
            if let firstEnhanced = enhancedVoices.first {
                return firstEnhanced
            }
        }

        // 7. Check for Alex (legendary high-quality voice on Apple platforms)
        if langPrefix == "en", let alex = matchingVoices.first(where: { $0.name == "Alex" || $0.identifier.contains("Alex") }) {
            return alex
        }

        // 8. Look for Siri/neural voices by identifier
        if let siriVoice = matchingVoices.first(where: {
            $0.identifier.localizedCaseInsensitiveContains("siri") ||
            $0.identifier.localizedCaseInsensitiveContains("neural")
        }) {
            return siriVoice
        }

        // 9. Fallback to default voice for language or system default
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

        if isAutoDetectLanguageEnabled, let text, text.count >= 8 {
            // First check for CJK Japanese character ranges
            let hasJapanese = text.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value) || // Hiragana
                (0x30A0...0x30FF).contains(scalar.value)    // Katakana
            }
            if hasJapanese {
                return "ja-JP"
            }

            // Use Apple's on-device NLLanguageRecognizer for instant ML language detection
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let dominant = recognizer.dominantLanguage?.rawValue, !dominant.isEmpty {
                // If BCP-47 tag is two letters, map to primary dialect
                switch dominant.lowercased() {
                case "en": return "en-US"
                case "es": return "es-ES"
                case "fr": return "fr-FR"
                case "de": return "de-DE"
                case "ja": return "ja-JP"
                case "it": return "it-IT"
                case "pt": return "pt-BR"
                case "zh": return "zh-CN"
                case "ko": return "ko-KR"
                default: return dominant
                }
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
        let currentCadence = cadenceMode
        utterance.postUtteranceDelay = isSentenceUnit ? currentCadence.sentenceDelay : currentCadence.paragraphDelay

        utterance.pitchMultiplier = min(1.15, max(0.85, pitchMultiplier))
        utterance.volume = min(1.0, max(0.0, volume))
    }
}


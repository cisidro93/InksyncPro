import Foundation
import AVFoundation
import NaturalLanguage

// MARK: - EPUB Narration Engine

/// On-device Text-to-Speech narration engine for EPUB reading.
/// Tokenizes chapters into sentences, synchronizes live `<mark class="inksync-tts-active">` DOM highlighting
/// via `AVSpeechSynthesizerDelegate`, and coordinates automatic column page turns.
@MainActor
public final class EPUBNarrationEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    
    public static let shared = EPUBNarrationEngine()
    
    // State
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published public private(set) var currentSentenceIndex: Int = 0
    @Published public private(set) var totalSentences: Int = 0
    
    private let synthesizer = AVSpeechSynthesizer()
    private var sentences: [String] = []
    private var sentenceRanges: [Range<String.Index>] = []
    private var onSentenceHighlight: ((Int, String) -> Void)? = nil
    private var onChapterFinished: (() -> Void)? = nil
    
    override private init() {
        super.init()
        synthesizer.delegate = self
    }
    
    // MARK: - Public Playback Control API
    
    /// Splits chapter plain text into sentences and begins synchronized on-device narration.
    public func startReading(
        chapterText: String,
        startingAt sentenceIndex: Int = 0,
        voiceLanguage: String = "en-US",
        onSentenceHighlight: @escaping (Int, String) -> Void,
        onChapterFinished: (() -> Void)? = nil
    ) {
        stop()
        
        self.sentences = tokenizeSentences(from: chapterText)
        self.totalSentences = sentences.count
        self.onSentenceHighlight = onSentenceHighlight
        self.onChapterFinished = onChapterFinished
        
        guard !sentences.isEmpty else { return }
        
        self.currentSentenceIndex = max(0, min(sentenceIndex, sentences.count - 1))
        self.isPlaying = true
        self.isPaused = false
        
        speakCurrentSentence(language: voiceLanguage)
    }
    
    public func pause() {
        guard isPlaying && !isPaused else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPaused = true
    }
    
    public func resume() {
        guard isPlaying && isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }
    
    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        isPaused = false
        currentSentenceIndex = 0
        sentences.removeAll()
        onSentenceHighlight = nil
        onChapterFinished = nil
    }
    
    public func nextSentence(language: String = "en-US") {
        guard currentSentenceIndex < sentences.count - 1 else {
            stop()
            onChapterFinished?()
            return
        }
        currentSentenceIndex += 1
        synthesizer.stopSpeaking(at: .immediate)
        speakCurrentSentence(language: language)
    }
    
    public func previousSentence(language: String = "en-US") {
        guard currentSentenceIndex > 0 else { return }
        currentSentenceIndex -= 1
        synthesizer.stopSpeaking(at: .immediate)
        speakCurrentSentence(language: language)
    }
    
    // MARK: - Internal Speaking Routine
    
    private func speakCurrentSentence(language: String) {
        guard currentSentenceIndex < sentences.count else {
            stop()
            onChapterFinished?()
            return
        }
        
        let sentence = sentences[currentSentenceIndex]
        onSentenceHighlight?(currentSentenceIndex, sentence)
        
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = speechRate
        utterance.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.15
        
        synthesizer.speak(utterance)
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleUtteranceDidFinish(utterance)
        }
    }
    
    private func handleUtteranceDidFinish(_ utterance: AVSpeechUtterance) {
        guard isPlaying && !isPaused else { return }
        
        if currentSentenceIndex < sentences.count - 1 {
            currentSentenceIndex += 1
            let nextLang = utterance.voice?.language ?? "en-US"
            speakCurrentSentence(language: nextLang)
        } else {
            stop()
            onChapterFinished?()
        }
    }
    
    // MARK: - Sentence Tokenization
    
    private func tokenizeSentences(from text: String) -> [String] {
        var results: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let sentence = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                results.append(sentence)
            }
            return true
        }
        
        return results
    }
}

import Foundation
import AVFoundation
import MediaPlayer
import NaturalLanguage
import UIKit

// MARK: - EPUB Narration Engine

/// On-device Text-to-Speech narration engine for EPUB reading.
/// Tokenizes chapters into sentences, synchronizes live `<mark class="inksync-tts-active">` DOM highlighting
/// via `AVSpeechSynthesizerDelegate`, and coordinates automatic column page turns.
/// Conforms to `ReaderSpeechEngineProtocol` for full cross-engine HUD parity.
@MainActor
public final class EPUBNarrationEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, ReaderSpeechEngineProtocol {
    
    public static let shared = EPUBNarrationEngine()
    
    // MARK: - Published State
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public var speechRate: Float = 1.0 // Normalized multiplier against default rate
    @Published public var selectedVoice: AVSpeechSynthesisVoice? = nil
    @Published public private(set) var currentSentenceIndex: Int = 0
    @Published public private(set) var totalSentences: Int = 0
    @Published public private(set) var bookTitle: String = ""
    @Published public private(set) var chapterTitle: String = ""

    public var isActive: Bool {
        isPlaying || isPaused || !sentences.isEmpty
    }

    public var activeDisplayIndex: Int {
        totalSentences > 0 ? (currentSentenceIndex + 1) : 0
    }

    public var totalBlocksCount: Int {
        totalSentences
    }

    public var unitLabel: String {
        "Sentence"
    }

    public var activeTextSnippet: String {
        guard currentSentenceIndex >= 0 && currentSentenceIndex < sentences.count else { return "" }
        return sentences[currentSentenceIndex]
    }

    // MARK: - Voices
    public var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { $0.language < $1.language }
    }

    public var personalVoices: [AVSpeechSynthesisVoice] {
        if #available(iOS 17.0, *) {
            return AVSpeechSynthesisVoice.speechVoices().filter {
                $0.voiceTraits.contains(.isPersonalVoice)
            }
        }
        return []
    }
    
    private let synthesizer = AVSpeechSynthesizer()
    private var sentences: [String] = []
    private var activeVoiceLanguage: String = "en-US"
    private var onSentenceHighlight: ((Int, String) -> Void)? = nil
    private var onChapterFinished: (() -> Void)? = nil
    
    override private init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommandCenter()
    }
    
    // MARK: - Public Playback Control API
    
    /// Splits chapter plain text into sentences and begins synchronized on-device narration.
    public func startReading(
        chapterText: String,
        startingAt sentenceIndex: Int = 0,
        voiceLanguage: String = "en-US",
        title: String = "Book",
        chapterName: String = "",
        onSentenceHighlight: @escaping (Int, String) -> Void,
        onChapterFinished: (() -> Void)? = nil
    ) {
        stop()
        
        self.sentences = tokenizeSentences(from: chapterText)
        self.totalSentences = sentences.count
        self.activeVoiceLanguage = voiceLanguage
        self.bookTitle = title
        self.chapterTitle = chapterName
        self.onSentenceHighlight = onSentenceHighlight
        self.onChapterFinished = onChapterFinished
        
        guard !sentences.isEmpty else { return }
        
        self.currentSentenceIndex = max(0, min(sentenceIndex, sentences.count - 1))
        self.isPlaying = true
        self.isPaused = false
        
        configureAudioSession()
        speakCurrentSentence()
    }
    
    public func pause() {
        guard isPlaying && !isPaused else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    public func resume() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isPlaying = true
            updateNowPlayingInfo()
        } else if !sentences.isEmpty {
            speakCurrentSentence()
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }
    
    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        isPaused = false
        currentSentenceIndex = 0
        totalSentences = 0
        sentences.removeAll()
        onSentenceHighlight = nil
        onChapterFinished = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    public func nextBlock() {
        nextSentence()
    }

    public func previousBlock() {
        previousSentence()
    }

    public func nextSentence() {
        guard currentSentenceIndex < sentences.count - 1 else {
            stop()
            onChapterFinished?()
            return
        }
        currentSentenceIndex += 1
        synthesizer.stopSpeaking(at: .immediate)
        speakCurrentSentence()
    }
    
    public func previousSentence() {
        guard currentSentenceIndex > 0 else { return }
        currentSentenceIndex -= 1
        synthesizer.stopSpeaking(at: .immediate)
        speakCurrentSentence()
    }

    public func setRate(_ rate: Float) {
        self.speechRate = max(0.5, min(2.5, rate))
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentSentence()
        }
    }

    public func setVoice(_ voice: AVSpeechSynthesisVoice) {
        self.selectedVoice = voice
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentSentence()
        }
    }
    
    // MARK: - Internal Speaking Routine
    
    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentences.count else {
            stop()
            onChapterFinished?()
            return
        }
        
        let sentence = sentences[currentSentenceIndex]
        onSentenceHighlight?(currentSentenceIndex, sentence)
        
        let utterance = AVSpeechUtterance(string: sentence)
        let baseRate = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, baseRate * speechRate))
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.15

        if let selectedVoice {
            utterance.voice = selectedVoice
        } else if let personal = personalVoices.first {
            utterance.voice = personal
        } else {
            let isJapanese = sentence.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value) ||
                (0x30A0...0x30FF).contains(scalar.value) ||
                (0x4E00...0x9FAF).contains(scalar.value)
            }
            let lang = isJapanese ? "ja-JP" : activeVoiceLanguage
            utterance.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        
        isPlaying = true
        isPaused = false
        synthesizer.speak(utterance)
        updateNowPlayingInfo()
    }
    
    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = true
            self.isPaused = false
            self.updateNowPlayingInfo()
        }
    }
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleUtteranceDidFinish()
        }
    }
    
    private func handleUtteranceDidFinish() {
        guard isPlaying && !isPaused else { return }
        
        if currentSentenceIndex < sentences.count - 1 {
            currentSentenceIndex += 1
            speakCurrentSentence()
        } else {
            stop()
            onChapterFinished?()
        }
    }

    // MARK: - Audio Session & Lock Screen Integration

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Logger.shared.log("EPUBNarrationEngine: Audio session setup failed: \(error.localizedDescription)", category: "Audio", type: .error)
        }
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextSentence() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousSentence() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = activeTextSnippet.isEmpty ? "EPUB Narration" : activeTextSnippet
        info[MPMediaItemPropertyAlbumTitle] = bookTitle.isEmpty ? "Inksync Pro" : bookTitle
        info[MPMediaItemPropertyArtist] = chapterTitle.isEmpty ? "Reading Aloud" : chapterTitle
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speechRate) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentSentenceIndex)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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

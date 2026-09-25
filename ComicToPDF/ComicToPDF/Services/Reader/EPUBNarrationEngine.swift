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
final class EPUBNarrationEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, ReaderSpeechEngineProtocol {

    static let shared = EPUBNarrationEngine()

    // MARK: - Published State
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published var speechRate: Float = 1.0 // Normalized multiplier against default rate
    @Published var selectedVoice: AVSpeechSynthesisVoice? = nil
    @Published private(set) var currentSentenceIndex: Int = 0
    @Published private(set) var totalSentences: Int = 0
    @Published private(set) var bookTitle: String = ""
    @Published private(set) var chapterTitle: String = ""

    var isActive: Bool {
        isPlaying || isPaused || !sentences.isEmpty
    }

    var activeDisplayIndex: Int {
        totalSentences > 0 ? (currentSentenceIndex + 1) : 0
    }

    var totalBlocksCount: Int {
        totalSentences
    }

    var unitLabel: String {
        "Sentence"
    }

    var activeTextSnippet: String {
        guard currentSentenceIndex >= 0 && currentSentenceIndex < sentences.count else { return "" }
        return sentences[currentSentenceIndex]
    }

    // MARK: - Voices
    var availableVoices: [AVSpeechSynthesisVoice] {
        NaturalSpeechVoiceSelector.shared.sortedAvailableVoices
    }

    var personalVoices: [AVSpeechSynthesisVoice] {
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

    // MARK: - Playback Control API

    /// Splits chapter plain text into sentences and begins synchronized on-device narration.
    func startReading(
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

    func pause() {
        guard isPlaying && !isPaused else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isPlaying = true
            updateNowPlayingInfo()
        } else if !sentences.isEmpty {
            speakCurrentSentence()
        }
    }

    func togglePlayPause() {
        guard isActive else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
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

    func nextBlock() {
        nextSentence()
    }

    func previousBlock() {
        previousSentence()
    }

    func nextSentence() {
        guard currentSentenceIndex < sentences.count - 1 else {
            let completion = onChapterFinished
            prepareForChapterAdvance()
            completion?()
            return
        }
        currentSentenceIndex += 1
        synthesizer.stopSpeaking(at: .immediate)
        speakCurrentSentence()
    }

    /// Prepares engine for smooth chapter-turn continuity without tearing down the audio session
    func prepareForChapterAdvance() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        isPaused = false
        currentSentenceIndex = 0
        totalSentences = 0
        sentences.removeAll()
    }

    func previousSentence() {
        guard currentSentenceIndex > 0 else { return }
        currentSentenceIndex -= 1
        synthesizer.stopSpeaking(at: .immediate)
        speakCurrentSentence()
    }

    func setRate(_ rate: Float) {
        self.speechRate = max(0.5, min(2.5, rate))
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentSentence()
        }
    }

    func setVoice(_ voice: AVSpeechSynthesisVoice) {
        self.selectedVoice = voice
        NaturalSpeechVoiceSelector.shared.preferredVoiceIdentifier = voice.identifier
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentSentence()
        }
    }

    // MARK: - Internal Speaking Routine

    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentences.count else {
            let completion = onChapterFinished
            prepareForChapterAdvance()
            completion?()
            return
        }

        let sentence = sentences[currentSentenceIndex]
        onSentenceHighlight?(currentSentenceIndex, sentence)

        let utterance = AVSpeechUtterance(string: sentence)
        NaturalSpeechVoiceSelector.shared.configureNaturalUtterance(
            utterance,
            voice: selectedVoice ?? personalVoices.first,
            speechRate: speechRate,
            isSentenceUnit: true
        )

        isPlaying = true
        isPaused = false
        synthesizer.speak(utterance)
        updateNowPlayingInfo()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = true
            self.isPaused = false
            self.updateNowPlayingInfo()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
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
            let completion = onChapterFinished
            prepareForChapterAdvance()
            completion?()
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
            guard let self = self, self.isActive else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.resume() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.nextSentence() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.previousSentence() }
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

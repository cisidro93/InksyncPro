import Foundation
import AVFoundation
import MediaPlayer
import NaturalLanguage
import UIKit
import Combine

/// On-device Text-to-Speech narration engine for the Study Notebook, Cornell notes, and Zettelkasten cards.
/// Conforms to `ReaderSpeechEngineProtocol` to seamlessly share the unified `ReaderSpeechHUDView`.
@MainActor
final class NotebookSpeechNarrationEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, ReaderSpeechEngineProtocol {
    static let shared = NotebookSpeechNarrationEngine()

    // MARK: - Published State
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var currentBlockIndex: Int? = nil
    @Published private(set) var activeSentenceText: String = ""
    @Published var speechRate: Float = 1.0 // Multiplier against AVSpeechUtteranceDefaultSpeechRate
    @Published var selectedVoice: AVSpeechSynthesisVoice? = nil
    @Published private(set) var noteTitle: String = "Study Notes"

    var isActive: Bool {
        isPlaying || isPaused || !sentences.isEmpty
    }

    var totalBlocksCount: Int {
        sentences.count
    }

    var activeDisplayIndex: Int {
        guard let index = currentBlockIndex else { return 0 }
        return index + 1
    }

    var unitLabel: String {
        "Sentence"
    }

    var activeTextSnippet: String {
        activeSentenceText
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

    // MARK: - Internal State
    private let synthesizer = AVSpeechSynthesizer()
    private var sentences: [String] = []
    private var activeUtterance: AVSpeechUtterance?
    var onSentenceChanged: ((Int, String) -> Void)? = nil
    var onFinished: (() -> Void)? = nil

    override private init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommandCenter()
    }

    // MARK: - Playback Control API

    /// Parses markdown/plain note text into clean sentences and begins synchronized reading aloud.
    func startReading(
        text: String,
        title: String = "Study Notes",
        startIndex: Int = 0,
        onSentenceChanged: ((Int, String) -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        stop()

        let cleaned = Self.cleanMarkdown(text)
        let tokenized = Self.tokenizeSentences(from: cleaned)
        guard !tokenized.isEmpty else { return }

        self.sentences = tokenized
        self.noteTitle = title
        self.onSentenceChanged = onSentenceChanged
        self.onFinished = onFinished
        self.currentBlockIndex = max(0, min(startIndex, sentences.count - 1))

        configureAudioSession()
        speakCurrentBlock()
    }

    /// Reads a collection of study card items (e.g. flashcards or quotes) sequentially.
    func startReadingCards(
        cards: [String],
        title: String = "Flashcards",
        startIndex: Int = 0,
        onSentenceChanged: ((Int, String) -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        stop()

        let validCards = cards.map { Self.cleanMarkdown($0) }.filter { !$0.isEmpty }
        guard !validCards.isEmpty else { return }

        self.sentences = validCards
        self.noteTitle = title
        self.onSentenceChanged = onSentenceChanged
        self.onFinished = onFinished
        self.currentBlockIndex = max(0, min(startIndex, sentences.count - 1))

        configureAudioSession()
        speakCurrentBlock()
    }

    /// Reads a single quote or excerpt.
    func playSingle(text: String, title: String = "Quote") {
        stop()
        let cleaned = Self.cleanMarkdown(text)
        guard !cleaned.isEmpty else { return }

        self.sentences = [cleaned]
        self.noteTitle = title
        self.currentBlockIndex = 0

        configureAudioSession()
        speakCurrentBlock()
    }

    func pause() {
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .immediate)
        }
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isPlaying = true
            updateNowPlayingInfo()
        } else if let index = currentBlockIndex, index < sentences.count {
            speakCurrentBlock()
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

    func nextBlock() {
        guard let currentIndex = currentBlockIndex else { return }
        if currentIndex + 1 < sentences.count {
            synthesizer.stopSpeaking(at: .immediate)
            currentBlockIndex = currentIndex + 1
            speakCurrentBlock()
        } else {
            stop()
            onFinished?()
        }
    }

    func previousBlock() {
        guard let currentIndex = currentBlockIndex, currentIndex > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentBlockIndex = currentIndex - 1
        speakCurrentBlock()
    }

    func setRate(_ rate: Float) {
        self.speechRate = max(0.5, min(2.5, rate))
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentBlock()
        }
    }

    func setVoice(_ voice: AVSpeechSynthesisVoice) {
        self.selectedVoice = voice
        NaturalSpeechVoiceSelector.shared.preferredVoiceIdentifier = voice.identifier
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentBlock()
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        isPaused = false
        currentBlockIndex = nil
        activeSentenceText = ""
        sentences.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speaking Routine

    private func speakCurrentBlock() {
        guard let index = currentBlockIndex, index >= 0, index < sentences.count else { return }
        let text = sentences[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            nextBlock()
            return
        }

        self.activeSentenceText = text
        onSentenceChanged?(index, text)

        let utterance = AVSpeechUtterance(string: text)
        NaturalSpeechVoiceSelector.shared.configureNaturalUtterance(
            utterance,
            voice: selectedVoice ?? personalVoices.first,
            speechRate: speechRate,
            isSentenceUnit: true
        )

        self.activeUtterance = utterance
        self.isPlaying = true
        self.isPaused = false
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
        Task { @MainActor in
            self.nextBlock()
        }
    }

    // MARK: - Audio Session & Lock Screen Integration

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Logger.shared.log("NotebookSpeechNarrationEngine: Audio session setup failed: \(error.localizedDescription)", category: "Audio", type: .error)
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
            Task { @MainActor in self.nextBlock() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.isActive else { return .noActionableNowPlayingItem }
            Task { @MainActor in self.previousBlock() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = activeSentenceText.isEmpty ? "Notebook Text" : activeSentenceText
        info[MPMediaItemPropertyAlbumTitle] = noteTitle
        info[MPMediaItemPropertyArtist] = "Inksync Pro Notes"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speechRate) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentBlockIndex ?? 0)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Text Processing Helpers

    private static func cleanMarkdown(_ text: String) -> String {
        var result = text
        // Remove markdown headers #, ##, etc.
        result = result.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        // Remove markdown bold/italic **text**, *text*
        result = result.replacingOccurrences(of: #"\*{1,2}([^\*]+)\*{1,2}"#, with: "$1", options: .regularExpression)
        // Remove page link stamps like [📍 Page 3](page:2)
        result = result.replacingOccurrences(of: #"\[📍\s*Page\s*\d+\]\(page:\d+\)"#, with: "", options: .regularExpression)
        // Remove bullet markers
        result = result.replacingOccurrences(of: #"(?m)^\s*[\*\-\+]\s+"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenizeSentences(from text: String) -> [String] {
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

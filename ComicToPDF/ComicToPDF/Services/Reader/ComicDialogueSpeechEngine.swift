import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// High-performance, on-device Text-to-Speech narration engine tailored for Comic/Manga dialogue.
///
/// Features:
/// - Sequences dialogue bubbles extracted via Apple Vision contour/OCR detection.
/// - Full playback transport controls: Play, Pause, Rewind, Fast-Forward, Speed (0.75x - 2.0x), Voice selection, Stop.
/// - Background audio playback via `AVAudioSession` (.playback, .spokenAudio, .duckOthers).
/// - Lock screen & Control Center media command integration (`MPRemoteCommandCenter`).
/// - Auto-page advance callback when all dialogue bubbles on a comic page finish playing.
/// - Conforms to `ReaderSpeechEngineProtocol` to drive the unified `ReaderSpeechHUDView`.
@MainActor
final class ComicDialogueSpeechEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, ReaderSpeechEngineProtocol {
    static let shared = ComicDialogueSpeechEngine()

    // MARK: - Published State
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var currentBlockIndex: Int? = nil
    @Published private(set) var activeBlock: TextBlock? = nil
    @Published private(set) var currentWordRange: NSRange = NSRange(location: 0, length: 0)
    @Published var speechRate: Float = 1.0 // Multiplier against AVSpeechUtteranceDefaultSpeechRate
    @Published var selectedVoice: AVSpeechSynthesisVoice? = nil
    @Published private(set) var activePageIndex: Int = 0
    @Published private(set) var bookTitle: String = ""

    var isActive: Bool {
        isPlaying || isPaused || activeBlock != nil
    }

    var totalBlocksCount: Int {
        dialogueBlocks.count
    }

    var activeDisplayIndex: Int {
        (currentBlockIndex ?? 0) + 1
    }

    var unitLabel: String {
        "Bubble"
    }

    var activeTextSnippet: String {
        activeBlock?.text ?? ""
    }

    // MARK: - Voices
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { $0.language < $1.language }
    }

    var personalVoices: [AVSpeechSynthesisVoice] {
        if #available(iOS 17.0, *) {
            return AVSpeechSynthesisVoice.speechVoices().filter {
                $0.voiceTraits.contains(.isPersonalVoice)
            }
        }
        return []
    }

    // MARK: - Internal Engine State
    private let synthesizer = AVSpeechSynthesizer()
    private var dialogueBlocks: [TextBlock] = []
    private var activeUtterance: AVSpeechUtterance?
    var onPageAdvanceRequested: (() -> Void)? = nil

    override private init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommandCenter()
    }

    // MARK: - Playback API

    /// Starts sequential narration for a collection of dialogue blocks on a comic page.
    func startReading(
        blocks: [TextBlock],
        startIndex: Int = 0,
        pageIndex: Int,
        title: String = "Comic Dialogue",
        onPageAdvanceRequested: (() -> Void)? = nil
    ) {
        guard !blocks.isEmpty else { return }
        stop()

        self.dialogueBlocks = blocks
        self.activePageIndex = pageIndex
        self.bookTitle = title
        self.onPageAdvanceRequested = onPageAdvanceRequested
        self.currentBlockIndex = max(0, min(startIndex, blocks.count - 1))
        self.activeBlock = dialogueBlocks[self.currentBlockIndex!]

        configureAudioSession()
        speakCurrentBlock()
    }

    /// Plays a single isolated dialogue block (e.g. from the AI Dialogue Lens tap).
    func playSingle(block: TextBlock, pageIndex: Int, title: String = "Comic Dialogue") {
        stop()
        self.dialogueBlocks = [block]
        self.activePageIndex = pageIndex
        self.bookTitle = title
        self.currentBlockIndex = 0
        self.activeBlock = block

        configureAudioSession()
        speakCurrentBlock()
    }

    /// Pauses active narration.
    func pause() {
        if synthesizer.isSpeaking && !synthesizer.isPaused {
            synthesizer.pauseSpeaking(at: .immediate)
        }
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
    }

    /// Resumes paused narration.
    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isPlaying = true
            updateNowPlayingInfo()
        } else if let index = currentBlockIndex, index < dialogueBlocks.count {
            speakCurrentBlock()
        }
    }

    /// Toggles play / pause.
    func togglePlayPause() {
        guard isActive else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Skips to the next dialogue bubble.
    func nextBlock() {
        guard let currentIndex = currentBlockIndex else { return }
        if currentIndex + 1 < dialogueBlocks.count {
            synthesizer.stopSpeaking(at: .immediate)
            currentBlockIndex = currentIndex + 1
            activeBlock = dialogueBlocks[currentBlockIndex!]
            speakCurrentBlock()
        } else {
            // End of page dialogue: notify page advance or stop
            let onPageAdvance = onPageAdvanceRequested
            stop()
            onPageAdvance?()
        }
    }

    /// Skips back to the previous dialogue bubble.
    func previousBlock() {
        guard let currentIndex = currentBlockIndex, currentIndex > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentBlockIndex = currentIndex - 1
        activeBlock = dialogueBlocks[currentBlockIndex!]
        speakCurrentBlock()
    }

    /// Sets playback speech rate (0.75x to 2.0x).
    func setRate(_ rate: Float) {
        self.speechRate = max(0.5, min(2.5, rate))
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentBlock()
        }
    }

    /// Sets voice for speech synthesis.
    func setVoice(_ voice: AVSpeechSynthesisVoice) {
        self.selectedVoice = voice
        if isPlaying {
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrentBlock()
        }
    }

    /// Stops playback completely, deactivates audio session, and clears highlights.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isPlaying = false
        isPaused = false
        currentBlockIndex = nil
        activeBlock = nil
        dialogueBlocks.removeAll()
        currentWordRange = NSRange(location: 0, length: 0)
        onPageAdvanceRequested = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speech Synthesis

    private func speakCurrentBlock() {
        guard let index = currentBlockIndex, index >= 0, index < dialogueBlocks.count else { return }
        let block = dialogueBlocks[index]
        let rawText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            nextBlock()
            return
        }

        self.activeBlock = block

        let utterance = AVSpeechUtterance(string: rawText)
        let baseRate = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, baseRate * speechRate))
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if let selectedVoice {
            utterance.voice = selectedVoice
        } else if let personal = personalVoices.first {
            utterance.voice = personal
        } else {
            // Auto-detect Japanese if Japanese characters are present
            let isJapanese = rawText.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value) || // Hiragana
                (0x30A0...0x30FF).contains(scalar.value) || // Katakana
                (0x4E00...0x9FAF).contains(scalar.value)    // Kanji
            }
            let lang = isJapanese ? "ja-JP" : (Locale.current.language.languageCode?.identifier ?? "en-US")
            utterance.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
        }

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
            // Move to next dialogue block
            self.nextBlock()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.currentWordRange = characterRange
        }
    }

    // MARK: - Audio Session & Lock Screen Integration

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Logger.shared.log("ComicDialogueSpeechEngine: Audio session failed: \(error.localizedDescription)", category: "Audio", type: .error)
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
        let activeText = activeBlock?.text ?? "Comic Dialogue"
        info[MPMediaItemPropertyTitle] = activeText
        info[MPMediaItemPropertyAlbumTitle] = bookTitle.isEmpty ? "Inksync Pro" : bookTitle
        info[MPMediaItemPropertyArtist] = "Page \(activePageIndex + 1)"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speechRate) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentBlockIndex ?? 0)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

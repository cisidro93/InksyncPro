import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Combine

/// Continuous Audiobook TTS Playback Engine
///
/// Features:
/// - Background audio playback via AVAudioSession (.playback, .spokenAudio)
/// - Lock screen & Control Center media controls (MPNowPlayingInfoCenter & MPRemoteCommandCenter)
/// - Real-time word and paragraph range tracking for visual highlighting inside reader views
/// - Speed adjustment (0.5x to 2.0x) and voice selection
@MainActor
final class AudiobookPlaybackManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = AudiobookPlaybackManager()

    // MARK: - Published State
    @Published var isPlaying: Bool = false
    @Published var currentText: String = ""
    @Published var currentParagraphIndex: Int = 0
    @Published var currentWordRange: NSRange = NSRange(location: 0, length: 0)
    @Published var playbackRate: Float = 1.0 // 0.5x to 2.0x
    @Published var bookTitle: String = ""
    @Published var chapterTitle: String = ""
    @Published var activeBookID: UUID? = nil
    @Published var selectedVoice: AVSpeechSynthesisVoice? = nil

    /// All available speech voices on device
    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
    }

    /// User's custom iOS Personal Voices (Settings -> Accessibility -> Personal Voice)
    var personalVoices: [AVSpeechSynthesisVoice] {
        if #available(iOS 17.0, *) {
            return AVSpeechSynthesisVoice.speechVoices().filter {
                $0.voiceTraits.contains(.isPersonalVoice)
            }
        } else {
            return []
        }
    }

    // MARK: - Internal Engine State
    private let synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [String] = []
    private var activeUtterance: AVSpeechUtterance?
    private var onParagraphChanged: ((Int) -> Void)?
    private var onFinished: (() -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommandCenter()
    }

    // MARK: - Public Controls

    /// Start or update continuous audiobook reading for a list of text paragraphs.
    func startReading(
        paragraphs: [String],
        bookTitle: String,
        chapterTitle: String,
        bookID: UUID? = nil,
        startParagraphIndex: Int = 0,
        onParagraphChanged: ((Int) -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        guard !paragraphs.isEmpty else { return }
        self.paragraphs = paragraphs
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        self.activeBookID = bookID
        self.currentParagraphIndex = max(0, min(startParagraphIndex, paragraphs.count - 1))
        self.onParagraphChanged = onParagraphChanged
        self.onFinished = onFinished

        configureAudioSession()
        speakParagraph(at: self.currentParagraphIndex)
    }

    /// Pause active TTS speech synthesis.
    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .immediate)
        }
        isPlaying = false
        updateNowPlayingInfo()
    }

    /// Resume paused TTS speech synthesis.
    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPlaying = true
            updateNowPlayingInfo()
        } else if !paragraphs.isEmpty {
            speakParagraph(at: currentParagraphIndex)
        }
    }

    /// Toggle Play / Pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Skip to the next paragraph.
    func nextParagraph() {
        guard currentParagraphIndex + 1 < paragraphs.count else {
            stop()
            onFinished?()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        currentParagraphIndex += 1
        speakParagraph(at: currentParagraphIndex)
    }

    /// Skip to the previous paragraph.
    func previousParagraph() {
        guard currentParagraphIndex > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentParagraphIndex -= 1
        speakParagraph(at: currentParagraphIndex)
    }

    /// Set playback rate (0.5x to 2.0x).
    func setPlaybackRate(_ rate: Float) {
        self.playbackRate = max(0.5, min(2.0, rate))
        if isPlaying {
            // Re-speak current paragraph at new rate
            synthesizer.stopSpeaking(at: .immediate)
            speakParagraph(at: currentParagraphIndex)
        }
    }

    /// Stop playback and release audio session.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        currentText = ""
        currentWordRange = NSRange(location: 0, length: 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speech Synthesis

    private func speakParagraph(at index: Int) {
        guard index >= 0 && index < paragraphs.count else { return }
        let text = paragraphs[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Skip empty whitespace paragraphs
            if index + 1 < paragraphs.count {
                currentParagraphIndex += 1
                speakParagraph(at: currentParagraphIndex)
            } else {
                stop()
                onFinished?()
            }
            return
        }

        currentText = text
        onParagraphChanged?(index)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * playbackRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if let selectedVoice {
            utterance.voice = selectedVoice
        } else if let personalVoice = personalVoices.first {
            utterance.voice = personalVoice
        } else if let defaultVoice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US") {
            utterance.voice = defaultVoice
        }

        activeUtterance = utterance
        isPlaying = true
        synthesizer.speak(utterance)
        updateNowPlayingInfo()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = true
            self.updateNowPlayingInfo()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentParagraphIndex + 1 < self.paragraphs.count {
                self.currentParagraphIndex += 1
                self.speakParagraph(at: self.currentParagraphIndex)
            } else {
                self.isPlaying = false
                self.onFinished?()
                self.stop()
            }
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

    // MARK: - Audio Session & Lock Screen Controls

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Logger.shared.log("AudiobookPlaybackManager: Audio session failed: \(error.localizedDescription)", category: "Audio", type: .error)
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
            Task { @MainActor in self?.nextParagraph() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousParagraph() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = chapterTitle.isEmpty ? "Audiobook Chapter" : chapterTitle
        info[MPMediaItemPropertyAlbumTitle] = bookTitle.isEmpty ? "Inksync Pro" : bookTitle
        info[MPMediaItemPropertyArtist] = "Inksync Pro Reader"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentParagraphIndex)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

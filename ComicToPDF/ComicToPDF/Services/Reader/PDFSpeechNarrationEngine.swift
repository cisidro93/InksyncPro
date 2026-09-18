import Foundation
import AVFoundation
import PDFKit
import MediaPlayer
import NaturalLanguage
import UIKit
import Combine

/// High-performance, on-device Text-to-Speech narration engine tailored for Native Vector PDFs.
///
/// Features:
/// - Tokenizes PDF page text into natural sentences using Apple's `NaturalLanguage` tokenizer.
/// - Resolves real-time geometric bounding boxes and line rects directly from PDFKit for on-page spatial highlighting.
/// - Full playback transport controls: Play, Pause, Rewind, Fast-Forward, Speed (0.75x - 2.0x), Voice selection, Stop.
/// - Background audio playback via `AVAudioSession` (.playback, .spokenAudio, .duckOthers).
/// - Lock screen & Control Center media command integration (`MPRemoteCommandCenter`).
/// - Automatic page-turn continuity when reading reaches the bottom of the page.
@MainActor
final class PDFSpeechNarrationEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, ReaderSpeechEngineProtocol {
    static let shared = PDFSpeechNarrationEngine()

    // MARK: - Sentence Block Model
    struct PDFSentenceBlock: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        let range: NSRange
        let boundsInPage: CGRect
        let lineRectsInPage: [CGRect]

        init(
            id: UUID = UUID(),
            text: String,
            range: NSRange,
            boundsInPage: CGRect,
            lineRectsInPage: [CGRect] = []
        ) {
            self.id = id
            self.text = text
            self.range = range
            self.boundsInPage = boundsInPage
            self.lineRectsInPage = lineRectsInPage.isEmpty ? [boundsInPage] : lineRectsInPage
        }
    }

    // MARK: - Published State
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var currentBlockIndex: Int? = nil
    @Published private(set) var activeSentence: PDFSentenceBlock? = nil
    @Published private(set) var activeSentenceBoundsInPage: CGRect? = nil
    @Published private(set) var activeSentenceLineRectsInPage: [CGRect] = []
    @Published private(set) var currentWordRange: NSRange = NSRange(location: 0, length: 0)
    @Published var speechRate: Float = 1.0 // Multiplier against AVSpeechUtteranceDefaultSpeechRate
    @Published var selectedVoice: AVSpeechSynthesisVoice? = nil
    @Published private(set) var activePageIndex: Int = 0
    @Published private(set) var bookTitle: String = ""

    var isActive: Bool {
        isPlaying || isPaused || activeSentence != nil
    }

    var totalBlocksCount: Int {
        sentenceBlocks.count
    }

    var activeDisplayIndex: Int {
        (currentBlockIndex ?? 0) + 1
    }

    var unitLabel: String {
        "Sentence"
    }

    var activeTextSnippet: String {
        activeSentence?.text ?? ""
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
    private var sentenceBlocks: [PDFSentenceBlock] = []
    private var activeUtterance: AVSpeechUtterance?
    var onSentenceChanged: ((PDFSentenceBlock) -> Void)? = nil
    var onPageAdvanceRequested: (() -> Void)? = nil

    override private init() {
        super.init()
        synthesizer.delegate = self
        setupRemoteCommandCenter()
    }

    // MARK: - Sentence Extraction Pipeline

    /// Tokenizes a PDFPage into natural sentences with exact PDF page coordinates.
    static func extractSentenceBlocks(from page: PDFPage) -> [PDFSentenceBlock] {
        guard let fullText = page.string, !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var blocks: [PDFSentenceBlock] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = fullText

        tokenizer.enumerateTokens(in: fullText.startIndex..<fullText.endIndex) { tokenRange, _ in
            let sentenceString = String(fullText[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentenceString.isEmpty {
                let nsRange = NSRange(tokenRange, in: fullText)
                if let selection = page.selection(for: nsRange) {
                    let pageBounds = selection.bounds(for: page)
                    let lineSelections = selection.selectionsByLine()
                    let lineRects = lineSelections.map { $0.bounds(for: page) }
                    
                    let block = PDFSentenceBlock(
                        text: sentenceString,
                        range: nsRange,
                        boundsInPage: pageBounds,
                        lineRectsInPage: lineRects.isEmpty ? [pageBounds] : lineRects
                    )
                    blocks.append(block)
                } else {
                    // Fallback if selection bounds could not be resolved
                    let block = PDFSentenceBlock(
                        text: sentenceString,
                        range: nsRange,
                        boundsInPage: .zero,
                        lineRectsInPage: []
                    )
                    blocks.append(block)
                }
            }
            return true
        }

        return blocks
    }

    // MARK: - Public Playback Control API

    /// Starts sequential narration for an entire PDF page.
    func startReading(
        page: PDFPage,
        pageIndex: Int,
        title: String = "Document",
        startIndex: Int = 0,
        onSentenceChanged: ((PDFSentenceBlock) -> Void)? = nil,
        onPageAdvanceRequested: (() -> Void)? = nil
    ) {
        stop()

        let blocks = Self.extractSentenceBlocks(from: page)
        guard !blocks.isEmpty else { return }

        self.sentenceBlocks = blocks
        self.activePageIndex = pageIndex
        self.bookTitle = title
        self.onSentenceChanged = onSentenceChanged
        self.onPageAdvanceRequested = onPageAdvanceRequested
        self.currentBlockIndex = max(0, min(startIndex, blocks.count - 1))

        configureAudioSession()
        speakCurrentBlock()
    }

    /// Plays a single isolated text snippet (e.g. from user selection HUD).
    func playSingle(
        text: String,
        boundsInPage: CGRect = .zero,
        pageIndex: Int,
        title: String = "Document"
    ) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let block = PDFSentenceBlock(
            text: trimmed,
            range: NSRange(location: 0, length: trimmed.utf16.count),
            boundsInPage: boundsInPage,
            lineRectsInPage: boundsInPage != .zero ? [boundsInPage] : []
        )
        self.sentenceBlocks = [block]
        self.activePageIndex = pageIndex
        self.bookTitle = title
        self.currentBlockIndex = 0

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
        } else if let index = currentBlockIndex, index < sentenceBlocks.count {
            speakCurrentBlock()
        }
    }

    /// Toggles play / pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    /// Skips to next sentence block.
    func nextBlock() {
        guard let currentIndex = currentBlockIndex else { return }
        if currentIndex + 1 < sentenceBlocks.count {
            synthesizer.stopSpeaking(at: .immediate)
            currentBlockIndex = currentIndex + 1
            speakCurrentBlock()
        } else {
            // End of page reached: request page advance
            if let onPageAdvance = onPageAdvanceRequested {
                stop()
                onPageAdvance()
            } else {
                stop()
            }
        }
    }

    /// Skips back to previous sentence block.
    func previousBlock() {
        guard let currentIndex = currentBlockIndex, currentIndex > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentBlockIndex = currentIndex - 1
        speakCurrentBlock()
    }

    /// Sets playback speech rate (0.5x to 2.0x).
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
        activeSentence = nil
        activeSentenceBoundsInPage = nil
        activeSentenceLineRectsInPage.removeAll()
        sentenceBlocks.removeAll()
        currentWordRange = NSRange(location: 0, length: 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speech Synthesis Routine

    private func speakCurrentBlock() {
        guard let index = currentBlockIndex, index >= 0, index < sentenceBlocks.count else { return }
        let block = sentenceBlocks[index]
        let rawText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            nextBlock()
            return
        }

        self.activeSentence = block
        self.activeSentenceBoundsInPage = block.boundsInPage
        self.activeSentenceLineRectsInPage = block.lineRectsInPage
        onSentenceChanged?(block)

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
            let isJapanese = rawText.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value) ||
                (0x30A0...0x30FF).contains(scalar.value) ||
                (0x4E00...0x9FAF).contains(scalar.value)
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
            Logger.shared.log("PDFSpeechNarrationEngine: Audio session setup failed: \(error.localizedDescription)", category: "Audio", type: .error)
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
            Task { @MainActor in self?.nextBlock() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousBlock() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        let activeText = activeSentence?.text ?? "Document Text"
        info[MPMediaItemPropertyTitle] = activeText
        info[MPMediaItemPropertyAlbumTitle] = bookTitle.isEmpty ? "Inksync Pro" : bookTitle
        info[MPMediaItemPropertyArtist] = "Page \(activePageIndex + 1)"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(speechRate) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentBlockIndex ?? 0)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

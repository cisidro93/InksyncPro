import Foundation
import AVFoundation

/// Universal contract for all InksyncPro text-to-speech reading engines.
/// Guarantees architectural and UI parity across Comic/Manga, PDF, and EPUB reading modes.
@MainActor
public protocol ReaderSpeechEngineProtocol: AnyObject, ObservableObject {
    // MARK: - State
    var isPlaying: Bool { get }
    var isPaused: Bool { get }
    var isActive: Bool { get }
    var activeDisplayIndex: Int { get }
    var totalBlocksCount: Int { get }
    var unitLabel: String { get } // e.g. "Bubble", "Sentence", "Paragraph"
    var speechRate: Float { get }
    var selectedVoice: AVSpeechSynthesisVoice? { get }
    var activeTextSnippet: String { get }

    // MARK: - Voices
    var availableVoices: [AVSpeechSynthesisVoice] { get }
    var personalVoices: [AVSpeechSynthesisVoice] { get }

    // MARK: - Playback Controls
    func togglePlayPause()
    func nextBlock()
    func previousBlock()
    func setRate(_ rate: Float)
    func setVoice(_ voice: AVSpeechSynthesisVoice)
    func stop()
}

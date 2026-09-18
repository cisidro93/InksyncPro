import SwiftUI
import AVFoundation

/// Floating, non-blocking liquid-glass audio HUD for all reader narration engines (Comics, PDFs, EPUBs).
///
/// Features:
/// - Real-time location tracker indicator (`Bubble 2/5`, `Sentence 3/14`)
/// - Full transport controls: Rewind, Play/Pause, Fast-Forward, Stop
/// - Speed adjustment menu (0.75x, 1.0x, 1.25x, 1.5x, 2.0x)
/// - Voice picker menu with iOS system voices & Personal Voices
/// - Live text snippet subtitle preview
struct ReaderSpeechHUDView<Engine: ReaderSpeechEngineProtocol>: View {
    @ObservedObject var engine: Engine
    var onClose: () -> Void

    @State private var isExpanded: Bool = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private let speedOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(engine: Engine, onClose: @escaping () -> Void) {
        self.engine = engine
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Main Glassmorphic Player Capsule
            HStack(spacing: 12) {
                // Animated Live Indicator & Location Counter
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isPlaying ? Color.purple : Color.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(engine.isPlaying ? 1.2 : 1.0)
                        .animation(engine.isPlaying ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: engine.isPlaying)
                    
                    if engine.totalBlocksCount > 0 {
                        Text("\(engine.activeDisplayIndex)/\(engine.totalBlocksCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: Capsule())

                // Rewind (Previous Sentence / Bubble)
                Button {
                    HapticEngine.light()
                    engine.previousBlock()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }
                .disabled(engine.activeDisplayIndex <= 1)
                .opacity(engine.activeDisplayIndex <= 1 ? 0.35 : 1.0)

                // Play / Pause Toggle
                Button {
                    HapticEngine.medium()
                    engine.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                // Fast-Forward (Next Sentence / Bubble)
                Button {
                    HapticEngine.light()
                    engine.nextBlock()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                }

                // Speed Menu
                Menu {
                    ForEach(speedOptions, id: \.self) { speed in
                        Button {
                            HapticEngine.selection()
                            engine.setRate(speed)
                        } label: {
                            HStack {
                                Text("\(speed, specifier: "%.2g")x")
                                if abs(engine.speechRate - speed) < 0.05 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(engine.speechRate, specifier: "%.2g")x")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }

                // Voice Picker Menu
                Menu {
                    Section("Personal Voices (On-Device)") {
                        if engine.personalVoices.isEmpty {
                            if #available(iOS 17.0, *) {
                                let status = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
                                if status == .notDetermined {
                                    Button {
                                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in }
                                    } label: {
                                        Label("Enable Personal Voice (Private)...", systemImage: "hand.raised.fill")
                                    }
                                } else {
                                    Text("Record in iOS Settings > Accessibility > Personal Voice")
                                }
                            } else {
                                Text("Requires iOS 17+")
                            }
                        } else {
                            ForEach(engine.personalVoices, id: \.identifier) { voice in
                                Button {
                                    HapticEngine.selection()
                                    engine.setVoice(voice)
                                } label: {
                                    HStack {
                                        Text(voice.name)
                                        if engine.selectedVoice?.identifier == voice.identifier {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section("System Voices") {
                        ForEach(filteredVoices, id: \.identifier) { voice in
                            Button {
                                HapticEngine.selection()
                                engine.setVoice(voice)
                            } label: {
                                HStack {
                                    Text("\(voice.name) (\(voice.language))")
                                    if engine.selectedVoice?.identifier == voice.identifier {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.14), in: Circle())
                }

                Divider()
                    .frame(height: 18)
                    .background(Color.white.opacity(0.25))

                // Stop & Close
                Button {
                    HapticEngine.light()
                    engine.stop()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.3), Color.purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)

            // Current Dialogue Subtitle Snippet
            if !engine.activeTextSnippet.isEmpty {
                Text(engine.activeTextSnippet)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 8, y: 3)
                    .frame(maxWidth: min(400, (UIScreen.main.bounds.width - 32)))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: engine.activeDisplayIndex)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: engine.isPlaying)
    }

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        let currentLangPrefix = String(Locale.current.language.languageCode?.identifier.prefix(2) ?? "en")
        let primary = engine.availableVoices.filter { $0.language.starts(with: currentLangPrefix) }
        let japanese = engine.availableVoices.filter { $0.language.starts(with: "ja") }
        let combined = primary + japanese
        return combined.isEmpty ? Array(engine.availableVoices.prefix(10)) : combined
    }
}

// Backward-compatibility typealiases
typealias ComicSpeechHUDView = ReaderSpeechHUDView<ComicDialogueSpeechEngine>
typealias PDFSpeechHUDView = ReaderSpeechHUDView<PDFSpeechNarrationEngine>
typealias EPUBNarrationHUDView = ReaderSpeechHUDView<EPUBNarrationEngine>
typealias EPUBSpeechHUDView = ReaderSpeechHUDView<EPUBNarrationEngine>
typealias NotebookSpeechHUDView = ReaderSpeechHUDView<NotebookSpeechNarrationEngine>

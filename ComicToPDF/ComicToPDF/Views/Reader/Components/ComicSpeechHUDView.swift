import SwiftUI
import AVFoundation

/// Floating, non-blocking liquid-glass audio HUD for all reader narration engines (Comics, PDFs, EPUBs).
///
/// Features:
/// - Real-time location tracker indicator (`Bubble 2/5`, `Sentence 3/14`)
/// - Full transport controls: Rewind, Play/Pause, Fast-Forward, Stop
/// - Speed adjustment menu (0.75x, 1.0x, 1.25x, 1.5x, 2.0x)
/// - Voice picker menu with English voices prioritized and Voice Audition / Preview testing
/// - Live text snippet subtitle preview
struct ReaderSpeechHUDView<Engine: ReaderSpeechEngineProtocol>: View {
    @ObservedObject var engine: Engine
    var onClose: () -> Void

    @State private var showVoiceSheet: Bool = false
    @StateObject private var previewSynth = VoicePreviewSynthesizer()
    @Environment(\.colorScheme) private var colorScheme

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
                        .fill(engine.isPlaying ? Color.inkViolet : Color.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(engine.isPlaying ? 1.2 : 1.0)
                        .animation(engine.isPlaying ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: engine.isPlaying)
                    
                    if engine.totalBlocksCount > 0 {
                        Text("\(engine.activeDisplayIndex)/\(engine.totalBlocksCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkText)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.inkSurfaceRaised, in: Capsule())

                // Rewind (Previous Sentence / Bubble)
                Button {
                    HapticEngine.light()
                    engine.previousBlock()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.inkText)
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
                            .fill(LinearGradient(colors: [.inkViolet, .inkBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        .foregroundStyle(Color.inkText)
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
                        .foregroundStyle(Color.inkText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.inkSurfaceRaised, in: Capsule())
                }

                // Voice Picker Menu
                Menu {
                    Button {
                        showVoiceSheet = true
                    } label: {
                        Label("Test Voices & Language Settings...", systemImage: "waveform.badge.magnifyingglass")
                    }

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

                    Section("English Voices (Curated)") {
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

                    Button {
                        showVoiceSheet = true
                    } label: {
                        Label("All Languages & Voices...", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.inkText)
                        .frame(width: 28, height: 28)
                        .background(Color.inkSurfaceRaised, in: Circle())
                }

                Divider()
                    .frame(height: 18)
                    .background(Color.inkBorderVisible)

                // Stop & Close
                Button {
                    HapticEngine.light()
                    previewSynth.stop()
                    engine.stop()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.3), Color.inkViolet.opacity(0.4)]
                                : [Color.black.opacity(0.12), Color.inkViolet.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 14, y: 6)

            // Current Dialogue Subtitle Snippet
            if !engine.activeTextSnippet.isEmpty {
                Text(engine.activeTextSnippet)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 8, y: 3)
                    .frame(maxWidth: 400)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: engine.activeDisplayIndex)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: engine.isPlaying)
        .sheet(isPresented: $showVoiceSheet, onDismiss: {
            previewSynth.stop()
        }) {
            NavigationStack {
                VoiceAuditionSheet(
                    engine: engine,
                    previewSynth: previewSynth,
                    isPresented: $showVoiceSheet
                )
            }
        }
    }

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        let englishVoices = engine.availableVoices
            .filter { $0.language.starts(with: "en") }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue > b.quality.rawValue
                }
                return a.name < b.name
            }
        return Array(englishVoices.prefix(12))
    }
}

// MARK: - Voice Preview Synthesizer (Audition Engine)

@MainActor
final class VoicePreviewSynthesizer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var activeTestingVoiceId: String? = nil
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func testVoice(_ voice: AVSpeechSynthesisVoice) {
        if activeTestingVoiceId == voice.identifier {
            synth.stopSpeaking(at: .immediate)
            activeTestingVoiceId = nil
            return
        }

        synth.stopSpeaking(at: .immediate)
        activeTestingVoiceId = voice.identifier
        HapticEngine.selection()

        let sampleText = "Hello! This is \(voice.name). Ready to read aloud."
        let utterance = AVSpeechUtterance(string: sampleText)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        activeTestingVoiceId = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.activeTestingVoiceId = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.activeTestingVoiceId = nil
        }
    }
}

// MARK: - Voice Audition & Language Selection Sheet

struct VoiceAuditionSheet<Engine: ReaderSpeechEngineProtocol>: View {
    @ObservedObject var engine: Engine
    @ObservedObject var previewSynth: VoicePreviewSynthesizer
    @Binding var isPresented: Bool

    @State private var languageScope: LanguageScope = .english
    @State private var searchText: String = ""

    enum LanguageScope: String, CaseIterable, Identifiable {
        case english = "English"
        case all = "All Languages"
        var id: String { rawValue }
    }

    private func sortVoices(_ a: AVSpeechSynthesisVoice, _ b: AVSpeechSynthesisVoice) -> Bool {
        if a.quality.rawValue != b.quality.rawValue {
            return a.quality.rawValue > b.quality.rawValue
        }
        return a.name < b.name
    }

    private var groupedVoices: [(title: String, voices: [AVSpeechSynthesisVoice])] {
        let pool: [AVSpeechSynthesisVoice]
        switch languageScope {
        case .english:
            pool = engine.availableVoices.filter { $0.language.starts(with: "en") }
        case .all:
            pool = engine.availableVoices
        }

        let filtered: [AVSpeechSynthesisVoice]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = pool
        } else {
            let query = searchText.lowercased()
            filtered = pool.filter {
                $0.name.lowercased().contains(query) ||
                $0.language.lowercased().contains(query)
            }
        }

        let dict = Dictionary(grouping: filtered) { voice -> String in
            let loc = Locale(identifier: voice.language)
            return loc.localizedString(forIdentifier: voice.language) ?? voice.language
        }

        return dict.map { (title: $0.key, voices: $0.value.sorted(by: sortVoices)) }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scope Picker
            Picker("Language", selection: $languageScope) {
                ForEach(LanguageScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            List {
                ForEach(groupedVoices, id: \.title) { group in
                    Section(header: Text(group.title).font(.system(size: 13, weight: .bold))) {
                        ForEach(group.voices, id: \.identifier) { voice in
                            voiceRow(voice)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search voice name or dialect...")
        }
        .navigationTitle("Read Aloud Voices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    previewSynth.stop()
                    isPresented = false
                }
                .font(.system(size: 16, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        let isSelected = (engine.selectedVoice?.identifier == voice.identifier)
        let isTesting = (previewSynth.activeTestingVoiceId == voice.identifier)

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name)
                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                        .foregroundColor(Color.inkText)

                    if voice.quality == .enhanced {
                        Text("Enhanced")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.inkGreen.opacity(0.18), in: Capsule())
                            .foregroundColor(Color.inkGreen)
                    } else if voice.quality == .premium {
                        Text("Premium")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.inkViolet.opacity(0.18), in: Capsule())
                            .foregroundColor(Color.inkViolet)
                    }
                }

                Text(voice.language)
                    .font(.system(size: 12))
                    .foregroundColor(Color.inkSecondary)
            }

            Spacer()

            // Play / Audition Button
            Button {
                previewSynth.testVoice(voice)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isTesting ? "speaker.wave.3.fill" : "speaker.wave.2")
                        .font(.system(size: 12, weight: .semibold))
                    Text(isTesting ? "Playing" : "Test")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isTesting ? Color.inkViolet.opacity(0.25) : Color.inkSecondary.opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .stroke(isTesting ? Color.inkViolet : Color.clear, lineWidth: 1)
                )
                .foregroundColor(isTesting ? Color.inkViolet : Color.inkText)
            }
            .buttonStyle(.borderless)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.inkViolet)
                    .padding(.leading, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticEngine.selection()
            engine.setVoice(voice)
        }
    }
}

// Backward-compatibility typealiases
typealias ComicSpeechHUDView = ReaderSpeechHUDView<ComicDialogueSpeechEngine>
typealias PDFSpeechHUDView = ReaderSpeechHUDView<PDFSpeechNarrationEngine>
typealias EPUBNarrationHUDView = ReaderSpeechHUDView<EPUBNarrationEngine>
typealias EPUBSpeechHUDView = ReaderSpeechHUDView<EPUBNarrationEngine>
typealias NotebookSpeechHUDView = ReaderSpeechHUDView<NotebookSpeechNarrationEngine>

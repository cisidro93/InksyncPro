import SwiftUI
import AVFoundation

@MainActor
struct NaturalSpeechSettingsView: View {
    @ObservedObject private var voiceSelector = NaturalSpeechVoiceSelector.shared
    @StateObject private var previewSynth = VoicePreviewSynthesizer()

    @State private var languageScope: LanguageScope = .english
    @State private var searchText: String = ""
    @State private var previewSpeechRate: Float = 1.0
    @State private var activeCadence: NaturalSpeechCadence = NaturalSpeechVoiceSelector.shared.cadenceMode
    @State private var autoDetectLang: Bool = NaturalSpeechVoiceSelector.shared.isAutoDetectLanguageEnabled
    @State private var showDownloadGuide: Bool = false

    enum LanguageScope: String, CaseIterable, Identifiable {
        case english = "English"
        case all = "All Installed"
        var id: String { rawValue }
    }

    private var currentDefaultVoice: AVSpeechSynthesisVoice {
        NaturalSpeechVoiceSelector.shared.resolveBestVoice()
    }

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        let pool: [AVSpeechSynthesisVoice]
        switch languageScope {
        case .english:
            pool = voiceSelector.sortedAvailableVoices.filter { $0.language.lowercased().starts(with: "en") }
        case .all:
            pool = voiceSelector.sortedAvailableVoices
        }

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return pool
        } else {
            let query = searchText.lowercased()
            return pool.filter {
                $0.name.lowercased().contains(query) ||
                $0.language.lowercased().contains(query)
            }
        }
    }

    private var groupedVoices: [(title: String, voices: [AVSpeechSynthesisVoice])] {
        let dict = Dictionary(grouping: filteredVoices) { voice -> String in
            let loc = Locale(identifier: voice.language)
            return loc.localizedString(forIdentifier: voice.language) ?? voice.language
        }
        return dict.map { (title: $0.key, voices: $0.value) }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        Form {
            // Section 1: Active Narrator Status & Live Audition
            Section(header: Text("Active Default Narrator")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(currentDefaultVoice.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(Color.inkText)

                                qualityBadge(for: currentDefaultVoice)
                            }
                            Text(currentDefaultVoice.language)
                                .font(.system(size: 13))
                                .foregroundColor(Color.inkSecondary)
                        }

                        Spacer()

                        Button {
                            previewSynth.testVoice(currentDefaultVoice)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: previewSynth.activeTestingVoiceId == currentDefaultVoice.identifier ? "stop.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(previewSynth.activeTestingVoiceId == currentDefaultVoice.identifier ? "Stop" : "Sample")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(previewSynth.activeTestingVoiceId == currentDefaultVoice.identifier ? Color.inkViolet.opacity(0.2) : Color.inkOrange.opacity(0.15))
                            )
                            .foregroundColor(previewSynth.activeTestingVoiceId == currentDefaultVoice.identifier ? Color.inkViolet : Color.inkOrange)
                        }
                        .buttonStyle(.plain)
                    }

                    if !voiceSelector.hasHighQualityNeuralVoiceInstalled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 14))
                            Text("Only standard voices found. Download Apple's free studio-grade Neural voices in iOS Settings for the most natural reading experience.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            // Section 2: Cadence & Breathing Pauses
            Section(
                header: Text("Breathing Cadence & Flow"),
                footer: Text(activeCadence.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            ) {
                Picker("Sentence Pauses", selection: $activeCadence) {
                    ForEach(NaturalSpeechCadence.allCases) { cadence in
                        Text(cadence.rawValue).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: activeCadence) { _, newValue in
                    HapticEngine.selection()
                    NaturalSpeechVoiceSelector.shared.cadenceMode = newValue
                }
            }

            // Section 3: Language Detection & NLP
            Section(
                header: Text("Multilingual Intelligence"),
                footer: Text("When enabled, InkSync Pro uses Apple's on-device NaturalLanguage framework to recognize the language of each document and automatically switch to native neural pronunciation.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            ) {
                Toggle("Auto-Detect Document Language", isOn: $autoDetectLang)
                    .onChange(of: autoDetectLang) { _, newValue in
                        HapticEngine.selection()
                        NaturalSpeechVoiceSelector.shared.isAutoDetectLanguageEnabled = newValue
                    }
            }

            // Section 4: Guide on Downloading Apple Neural Voices
            Section {
                Button {
                    showDownloadGuide.toggle()
                    HapticEngine.selection()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("How to Unlock Studio Neural Voices")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color.inkText)
                            Text("Ava, Zoe, Evan, Nathan, and Siri voices (Free from Apple)")
                                .font(.caption2)
                                .foregroundColor(Color.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: showDownloadGuide ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }

                if showDownloadGuide {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apple provides high-fidelity neural voices at no charge on iOS:")
                            .font(.footnote)
                            .foregroundColor(.primary)

                        Text("1. Open the iOS **Settings** app\n2. Navigate to **Accessibility** > **Spoken Content** > **Voices**\n3. Select your language (e.g. English)\n4. Tap the download icon next to any **Premium** or **Enhanced** voice (e.g. *Ava*, *Zoe*, or *Nathan*)\n5. Return to InkSync Pro to enjoy studio-grade narration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            // Section 5: Voice Selection Library
            Section(header: Text("Installed Apple Voices")) {
                Picker("Language Filter", selection: $languageScope) {
                    ForEach(LanguageScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                ForEach(groupedVoices, id: \.title) { group in
                    Section(header: Text(group.title).font(.system(size: 12, weight: .bold))) {
                        ForEach(group.voices, id: \.identifier) { voice in
                            voiceRow(voice)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search voice name or dialect...")
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.inkBackground.ignoresSafeArea())
        .listRowBackground(Color.inkSurface.opacity(0.4))
        .navigationTitle("Natural Speech Engine")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            previewSynth.stop()
        }
    }

    @ViewBuilder
    private func qualityBadge(for voice: AVSpeechSynthesisVoice) -> some View {
        if #available(iOS 17.0, *), voice.voiceTraits.contains(.isPersonalVoice) {
            Text("Personal Voice")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.2), in: Capsule())
                .foregroundColor(.purple)
        } else if voice.quality == .premium {
            Text("Premium Neural")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.inkViolet.opacity(0.2), in: Capsule())
                .foregroundColor(Color.inkViolet)
        } else if voice.quality == .enhanced {
            Text("Enhanced Neural")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.inkGreen.opacity(0.2), in: Capsule())
                .foregroundColor(Color.inkGreen)
        } else {
            Text("Standard")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        let isSelected = (voiceSelector.preferredVoiceIdentifier == voice.identifier)
        let isTesting = (previewSynth.activeTestingVoiceId == voice.identifier)

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name)
                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                        .foregroundColor(Color.inkText)

                    qualityBadge(for: voice)
                }

                Text(voice.language)
                    .font(.system(size: 12))
                    .foregroundColor(Color.inkSecondary)
            }

            Spacer()

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
                    Capsule().fill(isTesting ? Color.inkViolet.opacity(0.25) : Color.inkSecondary.opacity(0.12))
                )
                .overlay(
                    Capsule().stroke(isTesting ? Color.inkViolet : Color.clear, lineWidth: 1)
                )
                .foregroundColor(isTesting ? Color.inkViolet : Color.inkText)
            }
            .buttonStyle(.plain)

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
            voiceSelector.preferredVoiceIdentifier = voice.identifier
        }
    }
}

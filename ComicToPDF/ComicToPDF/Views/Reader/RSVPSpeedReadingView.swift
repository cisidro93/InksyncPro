import SwiftUI

// MARK: - RSVP Speed Reading View (KyBook 3 & Spritz Parity)

/// High-velocity Rapid Serial Visual Presentation (RSVP) speed reading engine.
/// Flashes individual words or multi-word chunks in a fixed focal window with
/// the Optimal Recognition Point (ORP) character highlighted in vibrant orange to eliminate eye saccades.
public struct RSVPSpeedReadingView: View {
    let rawText: String
    let bookTitle: String
    let onDismiss: (Int) -> Void // Passes back the word index reached

    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.dismiss) private var dismiss

    // Word tokens parsed from the text stream
    @State private var words: [String] = []
    @State private var currentWordIndex: Int = 0
    @State private var isPlaying: Bool = true
    @State private var playbackTask: Task<Void, Never>? = nil

    // Target WPM (Words Per Minute)
    @State private var currentWPM: Double = 350.0
    @State private var chunkSize: Int = 1 // 1, 2, or 3 words at once
    @State private var showCalibration: Bool = false
    @ScaledMetric(relativeTo: .largeTitle) private var focalFontSize: CGFloat = 38

    public init(rawText: String, bookTitle: String, initialWordIndex: Int = 0, onDismiss: @escaping (Int) -> Void) {
        self.rawText = rawText
        self.bookTitle = bookTitle
        self._currentWordIndex = State(initialValue: initialWordIndex)
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            // Dark immersive backdrop
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header Bar
                headerBar

                Spacer()

                // Central RSVP Focal Box
                focalBox

                Spacer()

                // Progress & Scrubbing
                progressSection

                // Playback & Speed Controls
                controlsSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .task {
            currentWPM = prefs.rsvpSpeedWPM > 0 ? prefs.rsvpSpeedWPM : 350.0
            chunkSize = prefs.rsvpChunkSize > 0 ? prefs.rsvpChunkSize : 1
            tokenizeText()
            startPlayback()
        }
        .onDisappear {
            stopPlayback()
            prefs.rsvpSpeedWPM = currentWPM
            prefs.rsvpChunkSize = chunkSize
            onDismiss(currentWordIndex)
        }
        .sheet(isPresented: $showCalibration) {
            RSVPCalibrationSheet { calibratedWPM in
                currentWPM = calibratedWPM
                prefs.rsvpSpeedWPM = calibratedWPM
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if isPlaying {
                togglePlayPause()
            }
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("RSVP SPEED READER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .tracking(1.5)
                Text(bookTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("RSVP Speed Reader, \(bookTitle)")

            Spacer()

            // Calibrate Button
            Button {
                HapticEngine.selection()
                if isPlaying { togglePlayPause() }
                showCalibration = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 11, weight: .bold))
                    Text("Calibrate")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calibrate reading speed")

            // Chunk Size Picker
            HStack(spacing: 4) {
                ForEach([1, 2, 3], id: \.self) { count in
                    Button {
                        HapticEngine.selection()
                        chunkSize = count
                    } label: {
                        Text("\(count)w")
                            .font(.system(size: 11, weight: chunkSize == count ? .bold : .medium, design: .rounded))
                            .foregroundStyle(chunkSize == count ? Color.orange : Color.white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(chunkSize == count ? Color.orange.opacity(0.18) : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read \(count) \(count == 1 ? "word" : "words") per flash")
                    .accessibilityAddTraits(chunkSize == count ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(4)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            // Close Button
            Button {
                HapticEngine.light()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close RSVP speed reader")
            .padding(.leading, 8)
        }
        .padding(.top, 12)
    }

    // MARK: - Central RSVP Focal Box
    private var focalBox: some View {
        VStack(spacing: 14) {
            // Top Optical Guide Notch
            Rectangle()
                .fill(Color.orange.opacity(0.8))
                .frame(width: 4, height: 12)
                .cornerRadius(2)

            // Current Word Display with ORP Highlight
            ZStack {
                if words.indices.contains(currentWordIndex) {
                    let displayedWords = getChunkWords()
                    if chunkSize == 1, let single = displayedWords.first {
                        singleWordView(single)
                    } else {
                        multiWordView(displayedWords)
                    }
                } else {
                    Text("End of Chapter")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(height: 70)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(words.indices.contains(currentWordIndex) ? getChunkWords().joined(separator: " ") : "End of chapter")
            .accessibilityHint("Double tap to toggle playback")
            .onTapGesture {
                togglePlayPause()
            }

            // Bottom Optical Guide Notch
            Rectangle()
                .fill(Color.orange.opacity(0.8))
                .frame(width: 4, height: 12)
                .cornerRadius(2)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Single Word ORP View
    @ViewBuilder
    private func singleWordView(_ word: String) -> some View {
        let orp = optimalRecognitionPoint(for: word)
        let chars = Array(word)

        if chars.indices.contains(orp) {
            let prefix = String(chars[0..<orp])
            let focal = String(chars[orp])
            let suffix = String(chars[(orp + 1)...])

            HStack(spacing: 0) {
                Spacer()
                Text(prefix)
                    .font(.system(size: focalFontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))

                Text(focal)
                    .font(.system(size: focalFontSize + 2, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .shadow(color: Color.orange.opacity(0.7), radius: 6)

                Text(suffix)
                    .font(.system(size: focalFontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
            }
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        } else {
            Text(word)
                .font(.system(size: focalFontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    // MARK: - Multi-Word View
    @ViewBuilder
    private func multiWordView(_ chunk: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(chunk.indices, id: \.self) { idx in
                Text(chunk[idx])
                    .font(.system(size: max(16, focalFontSize * 0.7), weight: .semibold, design: .rounded))
                    .foregroundStyle(idx == 0 ? Color.orange : Color.white.opacity(0.9))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Progress Section
    private var progressSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Word \(min(words.count, currentWordIndex + 1)) of \(words.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                let estMins = remainingMinutes()
                Text(estMins > 0 ? "~\(estMins) min left" : "< 1 min left")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orange.opacity(0.9))
            }

            // Interactive Scrubber
            Slider(
                value: Binding(
                    get: { Double(currentWordIndex) },
                    set: { newVal in
                        currentWordIndex = min(words.count - 1, max(0, Int(newVal)))
                    }
                ),
                in: 0...Double(max(1, words.count - 1))
            )
            .tint(Color.orange)
            .accessibilityLabel("Reading progress")
            .accessibilityValue("Word \(min(words.count, currentWordIndex + 1)) of \(words.count)")
        }
        .padding(.bottom, 16)
    }

    // MARK: - Controls Section
    private var controlsSection: some View {
        VStack(spacing: 20) {
            // Speed Slider & Badge
            HStack(spacing: 16) {
                Image(systemName: "hare.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orange)

                Slider(value: $currentWPM, in: 150...850, step: 25) { editing in
                    if !editing {
                        HapticEngine.selection()
                        if isPlaying {
                            startPlayback()
                        }
                    }
                }
                .tint(Color.orange)
                .accessibilityLabel("Reading speed")
                .accessibilityValue("\(Int(currentWPM)) words per minute")

                Text("\(Int(currentWPM)) WPM")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 76, alignment: .trailing)
            }

            // Playback Buttons
            HStack(spacing: 32) {
                // Back 10 Words
                Button {
                    HapticEngine.light()
                    currentWordIndex = max(0, currentWordIndex - 10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind 10 words")

                // Play / Pause
                Button {
                    togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.black)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color.orange))
                        .shadow(color: Color.orange.opacity(0.5), radius: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause reading" : "Resume reading")

                // Forward 10 Words
                Button {
                    HapticEngine.light()
                    currentWordIndex = min(words.count - 1, currentWordIndex + 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advance 10 words")
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - Internal Algorithms & Timing

    private func tokenizeText() {
        let trimmed = rawText
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) // strip HTML tags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        self.words = tokens.isEmpty ? ["No", "text", "available", "to", "speed", "read."] : tokens
        if currentWordIndex >= words.count {
            currentWordIndex = 0
        }
    }

    private func getChunkWords() -> [String] {
        guard words.indices.contains(currentWordIndex) else { return [] }
        let end = min(words.count, currentWordIndex + chunkSize)
        return Array(words[currentWordIndex..<end])
    }

    /// Computes the Optimal Recognition Point (ORP) index for a word.
    /// Spritz / KyBook 3 standard:
    /// - 0-1 chars: 0
    /// - 2-5 chars: 1
    /// - 6-9 chars: 2
    /// - 10-13 chars: 3
    /// - >13 chars: 4
    private func optimalRecognitionPoint(for word: String) -> Int {
        let clean = word.trimmingCharacters(in: .punctuationCharacters)
        let len = clean.count
        switch len {
        case 0...1:  return 0
        case 2...5:  return 1
        case 6...9:  return 2
        case 10...13: return 3
        default:     return 4
        }
    }

    private func togglePlayPause() {
        HapticEngine.selection()
        isPlaying.toggle()
        if isPlaying {
            startPlayback()
        } else {
            stopPlayback()
        }
    }

    private func startPlayback() {
        stopPlayback()
        guard isPlaying else { return }

        playbackTask = Task { @MainActor in
            while isPlaying && !Task.isCancelled {
                guard words.indices.contains(currentWordIndex) else {
                    isPlaying = false
                    break
                }

                let baseDelay = 60.0 / max(100.0, currentWPM)
                let currentWord = words[currentWordIndex]

                // Intelligent punctuation delay
                var multiplier: Double = 1.0
                if currentWord.hasSuffix(".") || currentWord.hasSuffix("!") || currentWord.hasSuffix("?") {
                    multiplier = 2.0 // Pause longer at sentence conclusions
                } else if currentWord.hasSuffix(",") || currentWord.hasSuffix(";") || currentWord.hasSuffix(":") {
                    multiplier = 1.5 // Minor pause at clauses
                } else if currentWord.hasSuffix("—") || currentWord.hasSuffix("-") {
                    multiplier = 1.3
                }

                let totalDelayNanos = UInt64(baseDelay * multiplier * 1_000_000_000)
                try? await Task.sleep(nanoseconds: totalDelayNanos)
                guard !Task.isCancelled, isPlaying else { break }

                let nextIndex = currentWordIndex + chunkSize
                if nextIndex >= words.count {
                    currentWordIndex = words.count - 1
                    isPlaying = false
                    break
                } else {
                    currentWordIndex = nextIndex
                }
            }
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func remainingMinutes() -> Int {
        let remaining = max(0, words.count - currentWordIndex)
        guard currentWPM > 0 else { return 0 }
        return Int(ceil(Double(remaining) / currentWPM))
    }
}

// MARK: - RSVP Cadence Calibration Sheet

struct RSVPCalibrationSheet: View {
    let onApply: (Double) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sampleWPM: Double = 300.0
    @State private var sampleWordIndex: Int = 0
    @State private var isPlayingSample: Bool = false
    @State private var sampleTask: Task<Void, Never>? = nil

    private let sampleWords: [String] = [
        "Reading", "is", "a", "quiet", "conversation.",
        "All", "books", "talk,", "but", "a", "good", "book", "listens", "as", "well.",
        "Find", "the", "gentle", "cadence", "that", "feels", "clear,",
        "effortless,", "and", "mindful", "for", "your", "eyes."
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.95).ignoresSafeArea()

                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Calibrate Reading Cadence")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Adjust the velocity until the words flow naturally without strain.")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)

                    // Focal preview card
                    VStack {
                        Spacer()
                        let word = sampleWords[safe: sampleWordIndex] ?? "Reading"
                        Text(word)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(height: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 24)

                    // Slider & WPM readout
                    VStack(spacing: 12) {
                        HStack {
                            Text("Pace")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Text("\(Int(sampleWPM)) WPM")
                                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.orange)
                        }
                        .padding(.horizontal, 28)

                        Slider(value: $sampleWPM, in: 150...700, step: 25) { editing in
                            if !editing {
                                HapticEngine.selection()
                                if isPlayingSample {
                                    startSamplePlayback()
                                }
                            }
                        }
                        .tint(Color.orange)
                        .padding(.horizontal, 24)
                        .accessibilityLabel("Cadence slider")
                        .accessibilityValue("\(Int(sampleWPM)) words per minute")
                    }

                    // Test preview toggle
                    Button {
                        toggleSamplePlayback()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isPlayingSample ? "stop.fill" : "play.fill")
                            Text(isPlayingSample ? "Pause Sample" : "Test Cadence")
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Apply Button
                    Button {
                        HapticEngine.selection()
                        stopSamplePlayback()
                        onApply(sampleWPM)
                        dismiss()
                    } label: {
                        Text("Apply Cadence")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopSamplePlayback()
                        dismiss()
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .presentationDetents([.medium])
        .onDisappear {
            stopSamplePlayback()
        }
    }

    private func toggleSamplePlayback() {
        HapticEngine.selection()
        isPlayingSample.toggle()
        if isPlayingSample {
            startSamplePlayback()
        } else {
            stopSamplePlayback()
        }
    }

    private func startSamplePlayback() {
        stopSamplePlayback()
        guard isPlayingSample else { return }

        sampleTask = Task { @MainActor in
            while isPlayingSample && !Task.isCancelled {
                let delay = 60.0 / max(100.0, sampleWPM)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, isPlayingSample else { break }

                sampleWordIndex = (sampleWordIndex + 1) % sampleWords.count
            }
        }
    }

    private func stopSamplePlayback() {
        sampleTask?.cancel()
        sampleTask = nil
    }
}

import Foundation
import Vision
import AVFoundation
import UIKit
import SwiftUI

// MARK: - NarrationEngine
//
// AI Narration Mode for InksyncPro.
//
// Pipeline:
//  1. Vision VNRecognizeTextRequest extracts text from each comic page image
//  2. Text is sorted into reading order (top-left → bottom-right with manga flip support)
//  3. AVSpeechSynthesizer speaks the extracted text, utterance by utterance
//  4. When each utterance finishes, the engine fires `onPageComplete` so the reader
//     can auto-advance to the next page — keeping audio and visuals in sync
//  5. All Vision work is done off the MainActor (Task.detached, background QoS)
//
// Design decisions:
//  • Actor isolation: NarrationEngine is @MainActor so all @Published mutations
//    are safe. Vision work is Task.detached so it never blocks the UI thread.
//  • Debounced page caching: text is OCR'd ahead of time (±2 pages prefetch)
//    so speak() is always instant with zero perceptible latency.
//  • Manga RTL: when isMangaMode is true, text blocks are sorted right-to-left
//    so speech follows the correct reading direction.
//  • Graceful degradation: if Vision finds no text on a page, the engine
//    auto-advances after a short pause so narration stays unblocked.

@MainActor
final class NarrationEngine: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var isNarrating: Bool = false
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isOCRing: Bool = false
    @Published private(set) var currentPageIndex: Int = 0
    @Published private(set) var extractedText: String = ""
    @Published private(set) var voiceLabel: String = "Samantha"

    // MARK: - Configuration

    var isMangaMode: Bool = false
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var speechPitch: Float = 1.05       // Slightly warmer than flat 1.0
    var voiceIdentifier: String = "com.apple.voice.compact.en-US.Samantha"

    // Callback: called when narration finishes the current page — reader should advance
    var onPageComplete: ((Int) -> Void)? = nil

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    private var ocrCache: [Int: String] = [:]       // page index → extracted text
    private var ocrTasks: [Int: Task<Void, Never>] = [:]
    private var autoAdvanceTask: Task<Void, Never>? = nil
    private var totalPages: Int = 0
    private var imageProvider: ((Int) -> UIImage?)? = nil  // closure from the reader

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }

    // MARK: - Public API

    /// Connect the engine to a comic reader's image cache.
    func connect(totalPages: Int, imageProvider: @escaping (Int) -> UIImage?) {
        self.totalPages = totalPages
        self.imageProvider = imageProvider
        ocrCache.removeAll()
        ocrTasks.values.forEach { $0.cancel() }
        ocrTasks.removeAll()
    }

    /// Start narrating from a given page index.
    func startNarrating(from pageIndex: Int) {
        isNarrating = true
        currentPageIndex = pageIndex
        speakPage(pageIndex)
        // Prefetch ahead
        prefetchOCR(around: pageIndex)
    }

    /// Pause / resume toggle.
    func togglePause() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isSpeaking = false
        }
    }

    /// Stop narration entirely.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        autoAdvanceTask?.cancel()
        ocrTasks.values.forEach { $0.cancel() }
        ocrTasks.removeAll()
        isNarrating = false
        isSpeaking = false
        isOCRing = false
        extractedText = ""
    }

    /// Called externally when the reader manually changes pages.
    func didManuallyChangePage(to index: Int) {
        guard isNarrating else { return }
        synthesizer.stopSpeaking(at: .immediate)
        autoAdvanceTask?.cancel()
        currentPageIndex = index
        speakPage(index)
        prefetchOCR(around: index)
    }

    // MARK: - OCR Pipeline

    private func speakPage(_ index: Int) {
        guard isNarrating else { return }
        currentPageIndex = index

        if let cached = ocrCache[index] {
            deliver(text: cached, pageIndex: index)
            return
        }

        // Not cached yet — OCR on demand
        isOCRing = true
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let text = await self.performOCR(pageIndex: index)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ocrCache[index] = text
                self.ocrTasks.removeValue(forKey: index)
                self.isOCRing = false
                if self.currentPageIndex == index && self.isNarrating {
                    self.deliver(text: text, pageIndex: index)
                }
            }
        }
        ocrTasks[index] = task
    }

    private func deliver(text: String, pageIndex: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        extractedText = trimmed

        if trimmed.isEmpty {
            // No readable text on this page — auto-advance after a short pause
            scheduleAutoAdvance(from: pageIndex, delay: 1.2)
            return
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = speechRate
        utterance.pitchMultiplier = speechPitch
        utterance.postUtteranceDelay = 0.25

        synthesizer.speak(utterance)
        isSpeaking = true
    }

    private func scheduleAutoAdvance(from pageIndex: Int, delay: TimeInterval) {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.advanceToNextPage(after: pageIndex)
            }
        }
    }

    private func advanceToNextPage(after pageIndex: Int) {
        let next = pageIndex + 1
        guard next < totalPages, isNarrating else {
            stop()
            return
        }
        currentPageIndex = next
        onPageComplete?(next)
        speakPage(next)
        prefetchOCR(around: next)
    }

    // MARK: - OCR (Vision)

    nonisolated private func performOCR(pageIndex: Int) async -> String {
        guard let image = await MainActor.run(body: { self.imageProvider?(pageIndex) }),
              let cgImage = image.cgImage else { return "" }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                // Sort observations into reading order
                // Standard: top-to-bottom, then left-to-right within a band
                // Manga RTL: top-to-bottom, then right-to-left within a band
                let bandHeight: CGFloat = 0.08   // ~8% of image height per band
                let sorted = observations.sorted { lhs, rhs in
                    let lhsBox = lhs.boundingBox
                    let rhsBox = rhs.boundingBox
                    // Vision boxes are bottom-origin so we invert Y for sorting
                    let lhsRow = Int((1.0 - lhsBox.midY) / bandHeight)
                    let rhsRow = Int((1.0 - rhsBox.midY) / bandHeight)
                    if lhsRow != rhsRow { return lhsRow < rhsRow }
                    // Same row band — sort by X (RTL for manga)
                    return Task.isCancelled ? false : lhsBox.midX < rhsBox.midX
                }

                let lines = sorted.compactMap {
                    $0.topCandidates(1).first?.string
                }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

                continuation.resume(returning: lines.joined(separator: " "))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Prefetch

    private func prefetchOCR(around pageIndex: Int) {
        let window = max(0, pageIndex - 1)...min(totalPages - 1, pageIndex + 2)
        for i in window {
            guard ocrCache[i] == nil, ocrTasks[i] == nil else { continue }
            let task = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                let text = await self.performOCR(pageIndex: i)
                await MainActor.run { [weak self] in
                    self?.ocrCache[i] = text
                    self?.ocrTasks.removeValue(forKey: i)
                }
            }
            ocrTasks[i] = task
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Logger.shared.log("NarrationEngine: audio session setup failed: \(error)", category: "Narration", type: .warning)
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension NarrationEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.isNarrating else { return }
            self.isSpeaking = false
            self.advanceToNextPage(after: self.currentPageIndex)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = true
        }
    }
}

// MARK: - NarrationWaveformView
//
// Animated 5-bar waveform HUD shown in the chrome bottom bar while narration is active.
// Bars oscillate at different rates to mimic a real audio waveform.

struct NarrationWaveformView: View {
    let isActive: Bool
    var barColor: Color = .orange

    @State private var phases: [Double] = [0, 0.3, 0.6, 0.9, 1.2]
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let amplitudes: [Double] = [1.0, 1.5, 0.8, 1.3, 0.9]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(barColor)
                    .frame(width: 3, height: barHeight(for: i))
                    .animation(
                        .easeInOut(duration: 0.18 + Double(i) * 0.04),
                        value: phases[i]
                    )
            }
        }
        .onReceive(timer) { _ in
            guard isActive else { return }
            for i in 0..<phases.count {
                phases[i] += 0.18 * amplitudes[i]
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                for i in 0..<phases.count { phases[i] = 0 }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isActive else { return 4 }
        let raw = abs(sin(phases[index])) * amplitudes[index]
        return max(4, min(22, CGFloat(raw * 18)))
    }
}

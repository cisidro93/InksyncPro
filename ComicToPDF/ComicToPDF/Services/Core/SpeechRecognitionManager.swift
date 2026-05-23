import SwiftUI
import Speech
import AVFoundation

/// Thread-safe manager for best-in-class Speech-to-Text (STT) capabilities in InkSync Pro.
/// Handles AVAudioEngine tapping, SFSpeechRecognizer, real-time audio power calculations (RMS/dB),
/// and continuous dictation session stitching without restarting the audio engine.
@MainActor
public final class SpeechRecognitionManager: ObservableObject {
    public static let shared = SpeechRecognitionManager()
    
    @Published public private(set) var isRecording = false
    @Published public private(set) var transcribedText = ""
    @Published public private(set) var currentSegmentText = ""
    @Published public private(set) var audioLevel: Float = 0.0 // Normalized 0.0 to 1.0
    @Published public private(set) var permissionGranted = false
    
    // Dynamic selected locale state
    @Published public var selectedLocale: Locale = Locale(identifier: "en-US")
    
    // Expose cached and sorted available locales supported by Apple's Speech system
    public var availableLocales: [Locale] {
        Self.cachedLocales
    }
    
    private static let cachedLocales: [Locale] = {
        Array(SFSpeechRecognizer.supportedLocales()).sorted {
            let nameA = $0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
            let nameB = $1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }
    }()
    
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    
    private var accumulatedText = ""
    
    // Timer to prevent exceeding iOS 60-second limit by silently recycling request
    private var sessionRestartTimer: Timer?
    private let sessionLimitDuration: TimeInterval = 50.0
    
    private init() {
        let sysLocale = Locale.current
        if SFSpeechRecognizer.supportedLocales().contains(sysLocale) {
            self.selectedLocale = sysLocale
        } else {
            self.selectedLocale = Locale(identifier: "en-US")
        }
        self.speechRecognizer = SFSpeechRecognizer(locale: self.selectedLocale)
        setupAudioSessionObservers()
    }
    
    /// Requests both microphone and speech recognition permissions
    public func requestPermissions() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        
        let audioGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        
        let allGranted = speechGranted && audioGranted
        self.permissionGranted = allGranted
        return allGranted
    }
    
    /// Starts a real-time recording session using selected or custom locale
    public func startDictation(locale: Locale? = nil) throws {
        guard !isRecording else { return }
        
        if let locale = locale {
            self.selectedLocale = locale
        }
        
        // Reset state
        transcribedText = ""
        currentSegmentText = ""
        accumulatedText = ""
        
        self.speechRecognizer = SFSpeechRecognizer(locale: selectedLocale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw NSError(domain: "SpeechRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available for locale \(selectedLocale.identifier)."])
        }
        
        try startSession(isRecycling: false)
    }
    
    private func startSession(isRecycling: Bool) throws {
        // Cancel existing task if any
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        // Force on-device offline recognition when available for best-in-class privacy and speed
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        
        self.recognitionRequest = request
        
        if !isRecycling {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            let req = self.recognitionRequest
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                // Dynamically feed active recognition request
                req?.append(buffer)
                self?.calculateAudioPower(buffer)
            }
            
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
        }
        
        isRecording = true
        
        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.currentSegmentText = text
                self.updateFinalText()
            }
            
            if error != nil || result?.isFinal == true {
                if self.isRecording && error != nil {
                    // Fail gracefully
                    self.stopDictation(commit: true)
                }
            }
        }
        
        // Setup session recycler to support infinite stitching
        setupSessionRecycler()
    }
    
    /// Stitches cumulative and active session strings
    private func updateFinalText() {
        if accumulatedText.isEmpty {
            transcribedText = currentSegmentText
        } else {
            transcribedText = accumulatedText + " " + currentSegmentText
        }
    }
    
    /// Sets up a timer to cycle requests before the 60-second limit
    private func setupSessionRecycler() {
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = Timer.scheduledTimer(withTimeInterval: sessionLimitDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                self.accumulateAndRestart()
            }
        }
    }
    
    /// Silent transition to a fresh request without restarting the audio engine
    private func accumulateAndRestart() {
        if !currentSegmentText.isEmpty {
            if accumulatedText.isEmpty {
                accumulatedText = currentSegmentText
            } else {
                accumulatedText += " " + currentSegmentText
            }
        }
        currentSegmentText = ""
        
        // End active request cleanly
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Start new request/task on top of the already running audio engine tap
        do {
            try startSession(isRecycling: true)
        } catch {
            isRecording = false
            Logger.shared.log("STT auto-recycler restart failed: \(error.localizedDescription)", category: "STT", type: .error)
        }
    }
    
    /// Computes RMS amplitude power to drive the voice visualizer node
    nonisolated private func calculateAudioPower(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataPointer = channelData[0]
        let frameLength = Int(buffer.frameLength)
        
        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelDataPointer[i]
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Float(frameLength))
        let normalizedLevel = min(max(rms * 4.0, 0.0), 1.0)
        
        Task { @MainActor in
            self.audioLevel = normalizedLevel
        }
    }
    
    /// Stops the dictation session and returns/saves the transcription
    public func stopDictation(commit: Bool) {
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = nil
        
        if isRecording {
            cleanupActiveSession()
            isRecording = false
        }
        
        let finalOutput = transcribedText
        
        // Restore standard audio category
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.shared.log("STT audio category reset failed: \(error.localizedDescription)", category: "STT", type: .warning)
        }
        
        if !commit {
            transcribedText = ""
        }
    }
    
    private func cleanupActiveSession() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
    }
    
    /// Set up observers for system interruption (phone calls, routing changes)
    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            Task { @MainActor in
                guard let userInfo = notification.userInfo,
                      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                
                if type == .began {
                    if self.isRecording {
                        self.stopDictation(commit: true)
                    }
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            Task { @MainActor in
                guard let userInfo = notification.userInfo,
                      let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                
                if reason == .oldDeviceUnavailable {
                    if self.isRecording {
                        self.stopDictation(commit: true)
                    }
                }
            }
        }
    }
}

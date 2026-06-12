import SwiftUI
import Speech

/// A premium real-time visualizer that displays speech input amplitude.
public struct LiveWaveformView: View {
    let amplitude: Float
    let isActive: Bool
    
    private let barCount = 7
    
    public init(amplitude: Float, isActive: Bool) {
        self.amplitude = amplitude
        self.isActive = isActive
    }
    
    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.5), value: amplitude)
            }
        }
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        guard isActive else { return 4 }
        let multiplier: CGFloat = {
            switch index {
            case 0, 6: return 0.2
            case 1, 5: return 0.5
            case 2, 4: return 0.8
            default: return 1.0
            }
        }()
        
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 24
        let dynamicHeight = minHeight + (maxHeight - minHeight) * CGFloat(amplitude) * multiplier
        
        let jitter = CGFloat.random(in: -1.5...1.5)
        return min(max(dynamicHeight + jitter, minHeight), maxHeight)
    }
}

/// A premium, glassmorphic control bar that displays STT status and manages commit/cancel states.
public struct SpeechDictationBar: View {
    @StateObject private var speechManager = SpeechRecognitionManager.shared
    let onTextCommitted: (String) -> Void
    
    public init(onTextCommitted: @escaping (String) -> Void) {
        self.onTextCommitted = onTextCommitted
    }
    
    // Curated popular locales list to keep SwiftUI Menu extremely fast and responsive
    private var displayLocales: [Locale] {
        var list: [Locale] = []
        
        list.append(speechManager.selectedLocale)
        
        let system = Locale.current
        if !list.contains(where: { $0.identifier == system.identifier }) {
            list.append(system)
        }
        
        let popularIDs = ["en-US", "en-GB", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "zh-CN"]
        for id in popularIDs {
            let loc = Locale(identifier: id)
            if !list.contains(where: { $0.identifier == loc.identifier }) {
                list.append(loc)
            }
        }
        
        return list.sorted {
            let nameA = $0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
            let nameB = $1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // Live Waveform Visualizer
            LiveWaveformView(amplitude: speechManager.audioLevel, isActive: speechManager.isRecording)
                .frame(width: 40, height: 24)
            
            // Language Dropdown Menu
            let langCode: String = {
                if #available(iOS 16.0, *) {
                    return speechManager.selectedLocale.language.languageCode?.identifier ?? "EN"
                } else {
                    return speechManager.selectedLocale.languageCode ?? "EN"
                }
            }()
            
            Menu {
                ForEach(displayLocales, id: \.identifier) { locale in
                    Button {
                        let isRecording = speechManager.isRecording
                        let final = speechManager.transcribedText
                        if isRecording {
                            speechManager.stopDictation(commit: true)
                            if !final.isEmpty {
                                onTextCommitted(final)
                            }
                        }
                        speechManager.selectedLocale = locale
                        if isRecording {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                do {
                                    try speechManager.startDictation(locale: locale)
                                } catch {
                                    // Log error or ignore
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            if speechManager.selectedLocale.identifier == locale.identifier {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(langCode.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                Text(speechManager.transcribedText.isEmpty ? "Listening..." : speechManager.transcribedText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Stop & Save (Commit)
            Button(action: {
                let final = speechManager.transcribedText
                speechManager.stopDictation(commit: true)
                if !final.isEmpty {
                    onTextCommitted(final)
                }
            }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command]) // Magic Keyboard Shortcut: Cmd + Return
            
            // Cancel / Discard
            Button(action: {
                speechManager.stopDictation(commit: false)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: []) // Magic Keyboard Shortcut: Escape
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.85))
                .background(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Apple Pencil Double Tap Support Modifiers
extension View {
    @ViewBuilder
    public func supportPencilDoubleTap(action: @escaping () -> Void) -> some View {
        if #available(iOS 17.5, *) {
            self.onPencilDoubleTap { _ in
                action()
            }
        } else {
            self.background(PencilDoubleTapResponder(action: action))
        }
    }
}

// MARK: - PencilDoubleTapResponder for iOS < 17.5
struct PencilDoubleTapResponder: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let interaction = UIPencilInteraction()
            interaction.delegate = context.coordinator
            window.addInteraction(interaction)
        }
        
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject, UIPencilInteractionDelegate {
        var action: () -> Void
        
        init(action: @escaping () -> Void) {
            self.action = action
        }
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            action()
        }
    }
}

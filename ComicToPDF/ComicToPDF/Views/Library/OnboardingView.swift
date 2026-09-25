//
//  OnboardingView.swift
//  InksyncPro
//
//  Restored 4-Screen Paged Onboarding Experience
//  Kavsoft ProMotion 120Hz Glassmorphic First-Run Flow
//

import SwiftUI
import UniformTypeIdentifiers

public struct OnboardingView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var currentPage: Int = 0
    @State private var rsvpWordIndex: Int = 0
    @State private var isRsvpPlaying: Bool = true
    @State private var rsvpTimer: Timer? = nil
    @State private var comicZoomStep: Int = 0
    
    var onImportRequested: (() -> Void)? = nil
    
    private let rsvpWords = [
        "Read", "at", "the", "speed", "of", "thought",
        "with", "InksyncPro's", "precision", "RSVP",
        "speed", "reading", "engine."
    ]
    
    public init(isPresented: Binding<Bool>, onImportRequested: (() -> Void)? = nil) {
        self._isPresented = isPresented
        self.onImportRequested = onImportRequested
    }
    
    public var body: some View {
        ZStack {
            // Ambient Neural Expression Background
            Color.black.ignoresSafeArea()
            
            RadialGradient(
                colors: [
                    currentPage == 0 ? Color.orange.opacity(0.25) :
                    currentPage == 1 ? Color.purple.opacity(0.25) :
                    currentPage == 2 ? Color.blue.opacity(0.25) : Color.green.opacity(0.25),
                    Color.black
                ],
                center: .top,
                startRadius: 20,
                endRadius: 500
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: currentPage)
            
            VStack(spacing: 0) {
                // Top Bar: Brand + Skip Button
                HStack {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    Text("InksyncPro")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    if currentPage < 3 {
                        Button {
                            HapticEngine.light()
                            completeOnboarding()
                        } label: {
                            Text("Skip")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                
                // Paged Carousel
                TabView(selection: $currentPage) {
                    heroScreen.tag(0)
                    rsvpScreen.tag(1)
                    smartTiersScreen.tag(2)
                    studyAndImportScreen.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: currentPage)
                .onChange(of: currentPage) { _, newPage in
                    HapticEngine.selection()
                    if newPage == 1 {
                        startRsvpTimer()
                    } else {
                        stopRsvpTimer()
                    }
                }
                
                // Bottom Controls: Page Indicator + Action Button
                VStack(spacing: 18) {
                    // Custom Capsule Indicator
                    HStack(spacing: 8) {
                        ForEach(0..<4) { index in
                            Capsule()
                                .fill(currentPage == index ? Color.orange : Color.white.opacity(0.25))
                                .frame(width: currentPage == index ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentPage)
                        }
                    }
                    
                    if currentPage < 3 {
                        Button {
                            HapticEngine.medium()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                currentPage += 1
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Continue")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 15, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                LinearGradient(
                                    colors: [Color.orange, Color.orange.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .shadow(color: Color.orange.opacity(0.35), radius: 12, y: 6)
                        }
                        .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 10) {
                            Button {
                                HapticEngine.success()
                                completeOnboarding()
                                onImportRequested?()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down.fill")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("Import Your First Title")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .shadow(color: Color.orange.opacity(0.35), radius: 12, y: 6)
                            }
                            
                            Button {
                                HapticEngine.light()
                                completeOnboarding()
                            } label: {
                                Text("Explore Library Directly")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .onDisappear {
            stopRsvpTimer()
        }
    }
    
    // MARK: - Screen 1: Hero
    private var heroScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // App Visual Graphic with Format Badges
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 220, height: 220)
                    .blur(radius: 20)
                
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.orange, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    HStack(spacing: 8) {
                        formatPill("EPUB", icon: "book.fill", color: .purple)
                        formatPill("CBZ / CBR", icon: "photo.on.rectangle.angled", color: .orange)
                        formatPill("PDF", icon: "doc.text.fill", color: .red)
                    }
                    
                    HStack(spacing: 8) {
                        formatPill("MANGA", icon: "arrow.left.arrow.right", color: .blue)
                        formatPill("STUDY", icon: "brain.head.profile", color: .green)
                    }
                }
            }
            
            VStack(spacing: 10) {
                Text("Everything You Read,\nAll in One Place")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                
                Text("The ultra-fast, native reading studio for digital comics, manga, books, and academic research.")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - Screen 2: RSVP Speed Reader
    private var rsvpScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("RSVP SPEED READING")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .tracking(1.2)
                
                Text("Read at the Speed of Thought")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            
            // Interactive RSVP Display Box
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .frame(height: 140)
                    
                    // Center Focal Marker
                    VStack {
                        Rectangle()
                            .fill(Color.orange.opacity(0.4))
                            .frame(width: 2, height: 16)
                        Spacer()
                        Rectangle()
                            .fill(Color.orange.opacity(0.4))
                            .frame(width: 2, height: 16)
                    }
                    .frame(height: 120)
                    
                    // Word Display
                    Text(rsvpWords[rsvpWordIndex])
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.1), value: rsvpWordIndex)
                }
                .padding(.horizontal, 24)
                
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.needle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text("250 WPM")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    
                    Button {
                        isRsvpPlaying.toggle()
                        if isRsvpPlaying {
                            startRsvpTimer()
                        } else {
                            stopRsvpTimer()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isRsvpPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11))
                            Text(isRsvpPlaying ? "Pause Demo" : "Resume")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            
            Text("Eliminate eye movement and vocalization fatigue with Rapid Serial Visual Presentation.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
            
            Spacer()
        }
    }
    
    // MARK: - Screen 3: Smart Tiers Comic Navigation
    private var smartTiersScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("COMIC & MANGA EXCELLENCE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.blue)
                    .tracking(1.2)
                
                Text("Smart Tiers™ Grid Flow")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            
            // Comic Page Simulation with Active Tier Highlight
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    comicPanel(index: 0, isHighlighted: comicZoomStep == 0)
                    comicPanel(index: 1, isHighlighted: comicZoomStep == 1)
                }
                HStack(spacing: 8) {
                    comicPanel(index: 2, isHighlighted: comicZoomStep == 2)
                    comicPanel(index: 3, isHighlighted: comicZoomStep == 3)
                }
            }
            .frame(width: 260, height: 180)
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .onAppear {
                startComicStepAnimation()
            }
            
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                Text("Adaptive M×N Panel Matrix")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            
            Text("Automatic quadrant division guides your eye seamlessly through dialogue and artwork, with Western and Manga direction modes.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
            
            Spacer()
        }
    }
    
    // MARK: - Screen 4: Study Layer & Import CTA
    private var studyAndImportScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("KNOWLEDGE & STUDY SUITE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                    .tracking(1.2)
                
                Text("Cornell & Zettelkasten Built-In")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            
            // Feature Grid Showcase
            VStack(spacing: 12) {
                studyFeatureRow(
                    icon: "pencil.and.outline",
                    color: .green,
                    title: "Cornell 3-Zone Note Paper",
                    subtitle: "Cues, Notes, and Summary seamlessly attached to each page."
                )
                
                studyFeatureRow(
                    icon: "brain.head.profile",
                    color: .purple,
                    title: "Zettelkasten Graph & Linking",
                    subtitle: "Auto-linked nodes reveal connections across your entire library."
                )
                
                studyFeatureRow(
                    icon: "sparkles",
                    color: .orange,
                    title: "ProMotion 120Hz Inking",
                    subtitle: "PencilKit and Metal accelerated graphics with zero latency."
                )
            }
            .padding(.horizontal, 24)
            
            Spacer()
        }
    }
    
    // MARK: - Helper Views & Actions
    
    private func formatPill(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.8))
    }
    
    private func comicPanel(index: Int, isHighlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHighlighted ? Color.blue.opacity(0.35) : Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHighlighted ? Color.blue : Color.white.opacity(0.15), lineWidth: isHighlighted ? 2 : 1)
            )
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundColor(isHighlighted ? .blue : .white.opacity(0.4))
                    Text("Panel \(index + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(isHighlighted ? .white : .white.opacity(0.4))
                }
            )
            .scaleEffect(isHighlighted ? 1.04 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHighlighted)
    }
    
    private func studyFeatureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }
    
    private func startRsvpTimer() {
        stopRsvpTimer()
        // 250 WPM = 60 / 250 = 0.24 seconds per word
        rsvpTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: true) { _ in
            Task { @MainActor in
                rsvpWordIndex = (rsvpWordIndex + 1) % rsvpWords.count
            }
        }
    }
    
    private func stopRsvpTimer() {
        rsvpTimer?.invalidate()
        rsvpTimer = nil
    }
    
    private func startComicStepAnimation() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                comicZoomStep = (comicZoomStep + 1) % 4
            }
        }
    }
    
    private func completeOnboarding() {
        hasCompletedOnboarding = true
        withAnimation(.easeOut(duration: 0.3)) {
            isPresented = false
        }
    }
}

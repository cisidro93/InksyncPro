import SwiftUI

// MARK: - Help Center View
struct HelpCenterView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            // Quick Start Section
            Section {
                NavigationLink {
                    QuickStartGuideView()
                } label: {
                    HelpRow(
                        icon: "bolt.fill",
                        iconColor: .orange,
                        title: "Quick Start Guide",
                        subtitle: "Get started in 5 minutes"
                    )
                }
                
                Button {
                    showingOnboarding = true
                } label: {
                    HelpRow(
                        icon: "play.circle.fill",
                        iconColor: .blue,
                        title: "Replay Welcome Tour",
                        subtitle: "View the feature walkthrough again"
                    )
                }
            } header: {
                Text("Getting Started")
            }
            
            // Feature Guides Section
            Section {
                NavigationLink {
                    FeatureGuideView(feature: .importing)
                } label: {
                    HelpRow(
                        icon: "square.and.arrow.down.fill",
                        iconColor: .green,
                        title: "Importing Comics",
                        subtitle: "CBZ, ZIP, and EPUB files"
                    )
                }
                
                NavigationLink {
                    FeatureGuideView(feature: .conversion)
                } label: {
                    HelpRow(
                        icon: "arrow.triangle.2.circlepath",
                        iconColor: .purple,
                        title: "Converting Files",
                        subtitle: "Standard vs Guided View"
                    )
                }
                
                NavigationLink {
                    FeatureGuideView(feature: .manga)
                } label: {
                    HelpRow(
                        icon: "arrow.left.arrow.right",
                        iconColor: .pink,
                        title: "Manga Mode",
                        subtitle: "Right-to-Left reading support"
                    )
                }
                
                NavigationLink {
                    FeatureGuideView(feature: .cloudSync)
                } label: {
                    HelpRow(
                        icon: "icloud.and.arrow.up.fill",
                        iconColor: .cyan,
                        title: "Quick Send to Kindle",
                        subtitle: "Share directly to your device"
                    )
                }
                
                NavigationLink {
                    FeatureGuideView(feature: .panelEditor)
                } label: {
                    HelpRow(
                        icon: "rectangle.split.3x1.fill",
                        iconColor: .indigo,
                        title: "Panel Editor",
                        subtitle: "Customize panel detection"
                    )
                }
            } header: {
                Text("Feature Guides")
            }
            
            // FAQ Section
            Section {
                NavigationLink {
                    FAQView()
                } label: {
                    HelpRow(
                        icon: "questionmark.circle.fill",
                        iconColor: .orange,
                        title: "Frequently Asked Questions",
                        subtitle: "Common questions answered"
                    )
                }
                
                NavigationLink {
                    TroubleshootingView()
                } label: {
                    HelpRow(
                        icon: "wrench.and.screwdriver.fill",
                        iconColor: .gray,
                        title: "Troubleshooting",
                        subtitle: "Fix common issues"
                    )
                }
            } header: {
                Text("Help & Support")
            }
            
            // About Section
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Help Center")
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingReplayView(isPresented: $showingOnboarding)
        }
    }
}

// MARK: - Help Row Component
struct HelpRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(iconColor)
                .cornerRadius(6)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Onboarding Replay (without dismissing to main app)
struct OnboardingReplayView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    
    let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "book.pages",
            title: "Welcome to InkSync Pro",
            description: "Transform your CBZ comics into beautiful, Kindle-optimized EPUBs with industry-leading conversion quality.",
            gradient: [Color(red: 249/255, green: 115/255, blue: 22/255), Color(red: 194/255, green: 65/255, blue: 12/255)]
        ),
        OnboardingPage(
            icon: "rectangle.split.3x1",
            title: "Guided View for Kindle",
            description: "Enable panel-by-panel reading on your Kindle device. Perfect for enjoying comics with precise navigation through each frame.",
            gradient: [Color.blue, Color.cyan]
        ),
        OnboardingPage(
            icon: "arrow.left.arrow.right",
            title: "Manga Mode Support",
            description: "Full Right-to-Left reading support for manga. Page progression and panel order automatically optimized for authentic manga experience.",
            gradient: [Color.purple, Color.pink]
        ),
        OnboardingPage(
            icon: "icloud.and.arrow.up",
            title: "Quick Send to Kindle",
            description: "Easy delivery to your Kindle library via Send to Kindle. Share your converted files and they'll appear in your library within minutes.",
            gradient: [Color.green, Color.mint]
        )
    ]
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: pages[currentPage].gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: currentPage)
            
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") {
                        isPresented = false
                    }
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(20)
                    .padding(.top, 60)
                    .padding(.trailing, 20)
                }
                
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        OnboardingPageView(page: pages[index], isAnimating: .constant(true))
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
            }
        }
    }
}

// MARK: - Quick Start Guide
struct QuickStartGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Step 1
                StepCard(
                    stepNumber: 1,
                    title: "Import Your Comic",
                    description: "Tap the + button or use 'Open In' from Files app to import a CBZ, ZIP, or EPUB comic file.",
                    icon: "plus.circle.fill",
                    color: .blue
                )
                
                // Step 2
                StepCard(
                    stepNumber: 2,
                    title: "Select File from Library",
                    description: "Your imported files appear in the Library. Tap on a file to open the conversion options.",
                    icon: "folder.fill",
                    color: .orange
                )
                
                // Step 3
                StepCard(
                    stepNumber: 3,
                    title: "Choose Conversion Mode",
                    description: "Select 'Standard' for full-page reading or 'Guided View' for panel-by-panel navigation on Kindle.",
                    icon: "slider.horizontal.3",
                    color: .purple
                )
                
                // Step 4
                StepCard(
                    stepNumber: 4,
                    title: "Set Reading Direction",
                    description: "Toggle 'Right-to-Left (Manga)' for Japanese manga or keep 'Left-to-Right' for Western comics.",
                    icon: "arrow.left.arrow.right",
                    color: .pink
                )
                
                // Step 5
                StepCard(
                    stepNumber: 5,
                    title: "Convert & Export",
                    description: "Tap 'Start Conversion', then long-press the converted file to export via 'Cloud Sync (Send to Kindle)'.",
                    icon: "icloud.and.arrow.up.fill",
                    color: .green
                )
                
                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle("Quick Start")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Step Card Component
struct StepCard: View {
    let stepNumber: Int
    let title: String
    let description: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Text("\(stepNumber)")
                    .font(.title2.bold())
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                    Text(title)
                        .font(.headline)
                }
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Feature Guide View
enum FeatureType {
    case importing, conversion, manga, cloudSync, panelEditor
    
    var title: String {
        switch self {
        case .importing: return "Importing Comics"
        case .conversion: return "Converting Files"
        case .manga: return "Manga Mode"
        case .cloudSync: return "Cloud Sync"
        case .panelEditor: return "Panel Editor"
        }
    }
}

struct FeatureGuideView: View {
    let feature: FeatureType
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch feature {
                case .importing:
                    FeatureContent(
                        sections: [
                            ("Supported Formats", "InkSync Pro supports CBZ, ZIP, and EPUB files containing comic images."),
                            ("From Files App", "Use the Share menu in Files and select InkSync Pro, or tap 'Open In'."),
                            ("From + Button", "Tap the + button in the Library to browse and import files."),
                            ("Automatic Processing", "Files are automatically scanned and prepared for conversion upon import.")
                        ]
                    )
                    
                case .conversion:
                    FeatureContent(
                        sections: [
                            ("Standard Mode", "Preserves original page layout. Best for tablets and large e-readers."),
                            ("Guided View Mode", "Adds panel-by-panel navigation. Perfect for Kindle devices where you want to zoom into each panel."),
                            ("Compression Options", "Choose between High Quality (largest files), Balanced, or Compact for smaller file sizes."),
                            ("Auto-Split", "Large files can be automatically split to meet Kindle's file size limits.")
                        ]
                    )
                    
                case .manga:
                    FeatureContent(
                        sections: [
                            ("What is Manga Mode?", "Enables Right-to-Left page progression, matching how Japanese manga is traditionally read."),
                            ("When to Use", "Enable for any content originally published in Japan or following manga conventions."),
                            ("Page Order", "Pages advance from right to left, and in landscape mode, the right page appears first."),
                            ("Panel Order", "In Guided View, panels are also navigated right-to-left, top-to-bottom.")
                        ]
                    )
                    
                case .cloudSync:
                    FeatureContent(
                        sections: [
                            ("Send to Kindle", "Long-press a converted file and select 'Quick Send to Kindle' from the share menu."),
                            ("Kindle Email", "Files are sent to your Kindle's email address (@kindle.com) for delivery."),
                            ("WiFi Sync", "Connect your Kindle to WiFi to receive the file. Delivery typically takes 2-5 minutes."),
                            ("Library Access", "Your comic will appear in your Kindle library on all linked devices.")
                        ]
                    )
                    
                case .panelEditor:
                    FeatureContent(
                        sections: [
                            ("Preview Detection", "Tap 'Preview Panel Detection' before conversion to see how panels are detected."),
                            ("Adjust Panels", "Drag panel corners to resize, or tap to add/remove panels as needed."),
                            ("Detection Modes", "Choose Automatic, Aggressive (finds more panels), Conservative (stricter), or Grid (2x2 split)."),
                            ("Save Changes", "Your panel edits are preserved and used during the final conversion.")
                        ]
                    )
                }
            }
            .padding()
        }
        .navigationTitle(feature.title)
        .navigationBarTitleDisplayMode(.large)
    }
}

struct FeatureContent: View {
    let sections: [(String, String)]
    
    var body: some View {
        ForEach(sections, id: \.0) { section in
            VStack(alignment: .leading, spacing: 8) {
                Text(section.0)
                    .font(.headline)
                Text(section.1)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
}

// MARK: - FAQ View
struct FAQView: View {
    var body: some View {
        List {
            FAQItem(
                question: "Why does my Kindle show fewer pages than expected?",
                answer: "In landscape mode, Kindle may display two pages as a 'spread'. This is normal behavior for reflowable content. The total content is the same."
            )
            
            FAQItem(
                question: "What's the difference between Standard and Guided View?",
                answer: "Standard mode shows full pages as-is. Guided View adds panel-by-panel navigation, letting you tap through each frame - ideal for smaller Kindle screens."
            )
            
            FAQItem(
                question: "Why isn't my file appearing on Kindle?",
                answer: "Ensure your Kindle is connected to WiFi. Files sent via Cloud Sync typically arrive within 2-5 minutes. Check your Kindle's email settings and spam folder."
            )
            
            FAQItem(
                question: "Can I convert EPUB files?",
                answer: "Yes! InkSync Pro can import and process EPUB files that contain comic images. The conversion workflow is the same as for CBZ files."
            )
            
            FAQItem(
                question: "How do I reduce file size?",
                answer: "Go to Settings > Optimization and select 'Compact' compression. You can also enable Auto-Split to break large files into smaller parts."
            )
            
            FAQItem(
                question: "What is the Panel Editor for?",
                answer: "The Panel Editor lets you preview and customize how panels are detected before conversion. Useful when automatic detection doesn't match your preferences."
            )
        }
        .navigationTitle("FAQ")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct FAQItem: View {
    let question: String
    let answer: String
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(question)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            
            if isExpanded {
                Text(answer)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Troubleshooting View
struct TroubleshootingView: View {
    var body: some View {
        List {
            Section(header: Text("Common Issues")) {
                TroubleshootItem(
                    issue: "Conversion fails or hangs",
                    solution: "Try restarting the app. If the issue persists, check if the source file is corrupted by opening it in another app."
                )
                
                TroubleshootItem(
                    issue: "Panels not detected correctly",
                    solution: "Use the Panel Editor to preview detection. Try different detection modes: Aggressive finds more panels, Conservative is stricter."
                )
                
                TroubleshootItem(
                    issue: "File too large for Kindle",
                    solution: "Enable Auto-Split in Settings to automatically break large files into smaller parts that Kindle can accept."
                )
                
                TroubleshootItem(
                    issue: "Images appear blurry",
                    solution: "Check Settings > Optimization. Choose 'High Quality' compression to preserve image detail at the cost of larger file sizes."
                )
                
                TroubleshootItem(
                    issue: "Kindle email delivery fails",
                    solution: "Verify your Kindle email address ends with @kindle.com. Check that your sending email is approved in Amazon's 'Approved Personal Document E-mail List'."
                )
            }
            
            Section(header: Text("Still Need Help?")) {
                NavigationLink {
                    LogsView()
                } label: {
                    Label("View Debug Logs", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct TroubleshootItem: View {
    let issue: String
    let solution: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(issue)
                    .font(.headline)
            }
            Text(solution)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

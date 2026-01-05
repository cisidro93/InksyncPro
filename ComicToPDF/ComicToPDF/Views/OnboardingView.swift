import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss
    @State private var currentPage = 0
    
    // Feature List
    let pages: [OnboardingPageModel] = [
        OnboardingPageModel(
            image: "book.fill",
            color: .orange,
            title: "Welcome to ComicToPDF",
            description: "The ultimate tool to convert, organize, and transfer your digital comic library to Kindle and iPad."
        ),
        OnboardingPageModel(
            image: "rectangle.split.3x3.fill",
            color: .blue,
            title: "Smart Panel Detection",
            description: "We automatically detect panels in double-page spreads and split them into single pages for perfect reading on Kindle."
        ),
        OnboardingPageModel(
            image: "wifi",
            color: .green,
            title: "Wi-Fi & Cloud Transfer",
            description: "Tap the Wi-Fi icon to start a local server and drag-and-drop comics from your computer, or import directly from Google Drive."
        ),
        OnboardingPageModel(
            image: "sparkles",
            color: .purple,
            title: "Auto-Metadata",
            description: "Add your ComicVine API Key in Settings to automatically fetch cover art, summaries, and release dates."
        )
    ]
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            
            VStack {
                // Skip Button
                HStack {
                    Spacer()
                    Button("Skip") { dismiss() }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                        .opacity(currentPage == pages.count - 1 ? 0 : 1)
                }
                
                // Swipeable Pages
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        OnboardingPageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                
                // Bottom Controls
                VStack(spacing: 20) {
                    if currentPage == pages.count - 1 {
                        Button(action: { dismiss() }) {
                            Text("Get Started")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .cornerRadius(14)
                                .padding(.horizontal)
                        }
                    } else {
                        Button(action: { withAnimation { currentPage += 1 } }) {
                            Text("Next")
                                .font(.headline)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.bottom, 50)
            }
        }
    }
}

// MARK: - Subviews & Models

struct OnboardingPageModel {
    let image: String
    let color: Color
    let title: String
    let description: String
}

struct OnboardingPageView: View {
    let page: OnboardingPageModel
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: page.image)
                .font(.system(size: 100))
                .foregroundColor(page.color)
                .padding()
                .background(
                    Circle()
                        .fill(page.color.opacity(0.1))
                        .frame(width: 200, height: 200)
                )
            
            Text(page.title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            
            Text(page.description)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
            
            Spacer()
        }
    }
}

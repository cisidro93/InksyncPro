import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @Environment(\.dismiss) var dismiss
    @State private var currentPage = 0
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
            TabView(selection: $currentPage) {
                OnboardingPage(
                    imageName: "doc.text.image.fill",
                    title: "Convert Comics",
                    description: "Easily convert your CBZ and CBR comic files into PDF or EPUB formats specifically optimized for reading.",
                    color: .blue
                )
                .tag(0)
                
                OnboardingPage(
                    imageName: "paperplane.fill",
                    title: "Send to Kindle",
                    description: "Send your converted comics directly to your Kindle device with a single tap using the 'Send to Kindle' feature.",
                    color: .orange
                )
                .tag(1)
                
                OnboardingPage(
                    imageName: "books.vertical.fill",
                    title: "Your Library",
                    description: "Organize your collection, manage metadata, and keep track of your reading history all in one place.",
                    color: .green,
                    isLastPage: true,
                    action: {
                        HapticManager.shared.notification(.success)
                        hasCompletedOnboarding = true
                        dismiss()
                    }
                )
                .tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
    }
}

struct OnboardingPage: View {
    let imageName: String
    let title: String
    let description: String
    let color: Color
    var isLastPage: Bool = false
    var action: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: imageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                .foregroundColor(color)
                .padding()
                .background(Circle().fill(color.opacity(0.1)).frame(width: 200, height: 200))
            
            VStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                
                Text(description)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            if isLastPage {
                Button(action: { action?() }) {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
            } else {
                Spacer().frame(height: 50 + 44) // Placeholder to balance layout
            }
        }
    }
}

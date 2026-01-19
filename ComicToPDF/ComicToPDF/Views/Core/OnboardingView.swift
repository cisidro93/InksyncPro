import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss
    @State private var currentPage = 0
    
    let pages: [OnboardingPageModel] = [
        OnboardingPageModel(
            image: "book.fill",
            color: .orange,
            title: "Welcome to Inksync Pro",
            description: "The ultimate tool to convert, organize, and transfer your digital comic library."
        ),
        OnboardingPageModel(
            image: "rectangle.split.3x3.fill",
            color: .blue,
            title: "Smart Panel Detection",
            description: "Automatically splits wide landscape spreads into single pages for perfect reading on Kindle."
        ),
        OnboardingPageModel(
            image: "bolt.fill",
            color: .yellow,
            title: "Instant Conversion",
            description: "Simply drag files into your library, and we'll automatically convert them to your preferred format in the background."
        ),
        OnboardingPageModel(
            image: "wifi",
            color: .green,
            title: "Wi-Fi Transfer",
            description: "Tap the Wi-Fi icon to drag-and-drop comics directly from your computer."
        )
    ]
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button("Skip") { dismiss() }.padding().foregroundColor(.secondary)
                        .opacity(currentPage == pages.count - 1 ? 0 : 1)
                }
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        OnboardingPageView(page: pages[index]).tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                
                VStack(spacing: 20) {
                    if currentPage == pages.count - 1 {
                        Button(action: { dismiss() }) {
                            Text("Get Started").font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding().background(Color.orange).cornerRadius(14).padding(.horizontal)
                        }
                    } else {
                        Button("Next") { withAnimation { currentPage += 1 } }.font(.headline)
                    }
                }.padding(.bottom, 50)
            }
        }
    }
}

struct OnboardingPageModel { let image: String; let color: Color; let title: String; let description: String }

struct OnboardingPageView: View {
    let page: OnboardingPageModel
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: page.image).font(.system(size: 100)).foregroundColor(page.color).padding()
                .background(Circle().fill(page.color.opacity(0.1)).frame(width: 200, height: 200))
            Text(page.title).font(.largeTitle).fontWeight(.bold).multilineTextAlignment(.center).padding(.top, 20)
            Text(page.description).font(.body).multilineTextAlignment(.center).foregroundColor(.secondary).padding(.horizontal, 40)
            Spacer()
        }
    }
}

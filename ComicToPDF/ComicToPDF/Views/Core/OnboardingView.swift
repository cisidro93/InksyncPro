import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss
    @State private var currentPage = 0
    
    let pages: [OnboardingPageModel] = [
        OnboardingPageModel(
            image: "sparkles.rectangle.stack.fill",
            color: .purple,
            title: "AI & Magic Wand",
            description: "Smart panel detection learns from your edits. Use the Magic Wand to instantly select panels, or let the AI do it for you."
        ),
        OnboardingPageModel(
            image: "iphone.gen3",
            color: .blue,
            title: "Device Optimization",
            description: "The app automatically tunes itself to your device's capabilities on startup for the best balance of quality and performance."
        ),
        OnboardingPageModel(
            image: "slider.horizontal.3",
            color: .orange,
            title: "Powerful Editor",
            description: "Trim edges, reorder pages, and adjust panels manually. Your library, exactly how you want it."
        ),
        OnboardingPageModel(
            image: "doc.on.doc.fill",
            color: .green,
            title: "Format Support",
            description: "Full support for CBZ, ZIP, EPUB, and PDF files. Drag and drop to import or transfer via Wi-Fi."
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

import SwiftUI

struct GuidedViewPreview: View {
    let pdf: ConvertedPDF
    @State var startingPageIndex: Int
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    @State private var currentPageIndex: Int
    @State private var currentPanelIndex: Int = 0
    @State private var currentImage: UIImage?
    @State private var panels: [CGRect] = []
    @State private var isLoading: Bool = true
    @State private var viewSize: CGSize = .zero
    @State private var isMovingBackwards: Bool = false
    
    init(pdf: ConvertedPDF, startingPageIndex: Int) {
        self.pdf = pdf
        self.startingPageIndex = startingPageIndex
        self._currentPageIndex = State(initialValue: startingPageIndex)
    }

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if isLoading {
                ProgressView().tint(.white)
            } else if let image = currentImage {
                if panels.isEmpty {
                    VStack {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                        Text("No panels detected on page \(currentPageIndex + 1)").foregroundColor(.white).padding()
                        HStack {
                            Button("Previous Page") { goPrevPage() }.buttonStyle(.bordered)
                            Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                            Button("Next Page") { goNextPage() }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    GeometryReader { geo in
                        ZStack {
                            if panels.indices.contains(currentPanelIndex) {
                                let rect = panels[currentPanelIndex]
                                let panelImage = cropImage(image, to: rect)
                                
                                Image(uiImage: panelImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .transition(.opacity)
                                    .id("\(currentPageIndex)-\(currentPanelIndex)")
                            }
                            
                            HStack(spacing: 0) {
                                Color.black.opacity(0.001)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if currentPanelIndex > 0 {
                                                currentPanelIndex -= 1
                                            } else {
                                                goPrevPage()
                                            }
                                        }
                                    }
                                
                                Color.black.opacity(0.001)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if currentPanelIndex < panels.count - 1 {
                                                currentPanelIndex += 1
                                            } else {
                                                goNextPage()
                                            }
                                        }
                                    }
                            }
                        }
                        .onAppear { viewSize = geo.size }
                    }
                    
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.white).padding()
                            }
                        }
                        Spacer()
                        HStack {
                            Text("Page \(currentPageIndex + 1) • Panel \(currentPanelIndex + 1) / \(panels.count)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(8)
                        }.padding(.bottom, 20)
                    }
                }
            }
        }
        .statusBarHidden(true)
        .task(id: currentPageIndex) {
            await loadPage(index: currentPageIndex, backwards: isMovingBackwards)
            isMovingBackwards = false // Reset after use
        }
    }
    
    private func goPrevPage() {
        if currentPageIndex > 0 {
            isMovingBackwards = true
            currentPageIndex -= 1
        } else {
            dismiss()
        }
    }
    
    private func goNextPage() {
        if currentPageIndex < pdf.pageCount - 1 {
            isMovingBackwards = false
            currentPageIndex += 1
        } else {
            dismiss()
        }
    }
    
    private func loadPage(index: Int, backwards: Bool) async {
        isLoading = true
        if let img = try? await conversionManager.extractFullPage(from: pdf, index: index) {
            let model = PageModelStore.shared.getPageModel(for: pdf.id, pageIndex: index)
            let normPanels = model.panels.map { p in
                CGRect(x: p.x / 1000.0, y: p.y / 1000.0, width: p.width / 1000.0, height: p.height / 1000.0)
            }
            await MainActor.run {
                self.currentImage = img
                self.panels = normPanels
                self.currentPanelIndex = backwards ? max(0, normPanels.count - 1) : 0
                self.isLoading = false
            }
        } else {
            await MainActor.run { isLoading = false }
        }
    }
    
    func cropImage(_ image: UIImage, to normalizedRect: CGRect) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        let cropRect = CGRect(x: normalizedRect.minX * width, y: normalizedRect.minY * height, width: normalizedRect.width * width, height: normalizedRect.height * height)
        if cropRect.width <= 0 || cropRect.height <= 0 || cropRect.isInfinite || cropRect.isEmpty { return image }
        let intersection = cropRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if let cgImage = image.cgImage?.cropping(to: intersection) {
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }
        return image
    }
}

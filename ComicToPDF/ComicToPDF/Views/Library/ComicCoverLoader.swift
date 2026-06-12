import SwiftUI

struct ComicCoverLoader: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var image: UIImage?

    private var isCloud: Bool {
        if case .cloud = pdf.sourceMode { return true }
        return false
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                    VStack(spacing: 6) {
                        Image(systemName: isCloud ? "icloud.and.arrow.down" : "photo")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                        if isCloud {
                            Text("Cloud")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                        }
                    }
                }
            }
        }
        .task {
            // 1. Try in-memory + disk cache first
            if image == nil {
                image = await conversionManager.loadCoverThumbnail(for: pdf)
            }
            // 2. If still nil and it's a cloud file, kick off background byte-range extraction
            if image == nil, isCloud {
                await CloudCoverExtractor.shared.extract(for: [pdf])
            }
        }
        // 3. Observe async extraction completion - refresh this cell when the cover arrives
        .onReceive(NotificationCenter.default.publisher(for: .cloudCoverReady)) { note in
            guard let pdfID = note.userInfo?["pdfID"] as? UUID,
                  pdfID == pdf.id,
                  let newImage = note.userInfo?["image"] as? UIImage else { return }
            withAnimation(.easeIn(duration: 0.3)) { image = newImage }
        }
    }
}

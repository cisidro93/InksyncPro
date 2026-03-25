import SwiftUI

struct ReadNowTabView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @StateObject private var tracker = ReaderProgressTracker.shared
    
    @State private var pdfToRead: ConvertedPDF?
    
    var continueReadingItems: [ConvertedPDF] {
        // Filter items that have progress < 1.0 but > 0.0, sorted by last opened
        let inProgress = conversionManager.convertedPDFs.filter { pdf in
            guard let prog = tracker.progress(for: pdf.id) else { return false }
            return prog.completionFraction > 0.0 && prog.completionFraction < 0.98
        }
        return inProgress.prefix(3).map { $0 }
    }
    
    var recentlyAddedItems: [ConvertedPDF] {
        return Array(conversionManager.convertedPDFs.suffix(5).reversed())
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    if !continueReadingItems.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Continue Reading")
                                .font(.title2).bold()
                                .padding(.horizontal)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(continueReadingItems) { pdf in
                                        ReadNowCard(pdf: pdf)
                                            .onTapGesture {
                                                pdfToRead = pdf
                                            }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    if !recentlyAddedItems.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Recently Added")
                                .font(.title3).bold()
                                .padding(.horizontal)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(recentlyAddedItems) { pdf in
                                        LibraryGridItem(pdf: pdf)
                                            .frame(width: 140)
                                            .onTapGesture {
                                                pdfToRead = pdf
                                            }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(.top)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("Read Now")
            .fullScreenCover(item: $pdfToRead) { pdf in
                SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
            }
        }
    }
}

struct ReadNowCard: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var tracker = ReaderProgressTracker.shared
    
    var body: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .bottomLeading) {
                if let uiImage = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
            }
            .frame(width: 200, height: 280)
            .cornerRadius(12)
            .clipped()
            
            Text(pdf.name)
                .font(.headline)
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)
            
            if let prog = tracker.progress(for: pdf.id) {
                ProgressView(value: prog.completionFraction)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(width: 200)
            }
        }
    }
}

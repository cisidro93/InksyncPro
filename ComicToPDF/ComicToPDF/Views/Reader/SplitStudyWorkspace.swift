import SwiftUI

struct SplitStudyWorkspace: View {
    let fileURL: URL
    let contentType: ContentType
    let pdf: ConvertedPDF?
    
    @AppStorage("study_split_fraction") private var splitFraction: Double = 0.65
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.dismiss) var dismiss
    @State private var showNotebook = false
    
    var body: some View {
        GeometryReader { geo in
            let isCompact = hSizeClass == .compact || geo.size.width < 700
            
            if isCompact {
                // iPhone or compact iPad view -> just reader, notebook is hidden
                ReaderView(fileURL: fileURL, contentType: contentType, pdf: pdf, onExit: { dismiss() })
            } else {
                HStack(spacing: 0) {
                    // Left: Reader
                    ReaderView(fileURL: fileURL, contentType: contentType, pdf: pdf, onExit: { dismiss() })
                        .frame(width: showNotebook ? geo.size.width * splitFraction : geo.size.width)
                    
                    if showNotebook {
                        // Divider
                        Rectangle()
                            .fill(Color.inkSurfaceRaised)
                            .frame(width: 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.inkTextTertiary)
                                    .frame(width: 2, height: 30)
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(coordinateSpace: .global)
                                    .onChanged { val in
                                        let newFraction = val.location.x / geo.size.width
                                        splitFraction = min(max(newFraction, 0.2), 0.8)
                                    }
                            )
                        
                        // Right: Notebook
                        StudyNotebookView(bookID: pdf?.id.uuidString ?? fileURL.lastPathComponent)
                            .frame(width: geo.size.width * (1.0 - splitFraction) - 8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Toggle Notebook Button layered over the Reader/Notebook
                    Button {
                        withAnimation(.spring()) {
                            showNotebook.toggle()
                            if showNotebook && splitFraction > 0.9 { splitFraction = 0.65 }
                        }
                    } label: {
                        Image(systemName: showNotebook ? "sidebar.right" : "sidebar.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.inkTextPrimary)
                            .padding(10)
                            .background(Color.inkSurfaceRaised.opacity(0.85))
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .padding(.top, 50)
                    .padding(.trailing, showNotebook ? geo.size.width * (1.0 - splitFraction) + 16 : 16)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}


import SwiftUI
import SwiftData

struct ZettelkastenCorkboardView: View {
    let annotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    
    // Camera state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    
    // Track if we need to initialize positions
    @State private var hasInitializedPositions = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                corkboardBackground
                    .ignoresSafeArea()
                
                // Infinite panning canvas
                ZStack {
                    ForEach(annotations) { annotation in
                        IndexCardView(annotation: annotation, pdfs: pdfs)
                            .position(
                                x: CGFloat(annotation.corkboardX ?? 0),
                                y: CGFloat(annotation.corkboardY ?? 0)
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        // Live dragging updates
                                        annotation.corkboardX = Double(value.location.x)
                                        annotation.corkboardY = Double(value.location.y)
                                    }
                                    .onEnded { _ in
                                        try? modelContext.save()
                                    }
                            )
                    }
                }
                .scaleEffect(scale)
                .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                        dragOffset = .zero
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(0.1, min(value.magnitude, 3.0))
                    }
            )
            .onAppear {
                initializePositionsIfNeeded(in: geo.size)
            }
        }
    }
    
    private var corkboardBackground: some View {
        // Scrivener style corkboard pattern or minimal gray
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.14) // Deep minimal gray
            : Color(red: 0.90, green: 0.88, blue: 0.85) // Subtle cork/paper tone
    }
    
    private func initializePositionsIfNeeded(in size: CGSize) {
        guard !hasInitializedPositions else { return }
        
        var didUpdate = false
        var col = 0
        var row = 0
        let cardWidth: CGFloat = 260
        let cardHeight: CGFloat = 180
        let padding: CGFloat = 40
        
        for annotation in annotations {
            if annotation.corkboardX == nil || annotation.corkboardY == nil {
                // Arrange unplaced cards in a grid
                let x = CGFloat(col) * (cardWidth + padding) + cardWidth/2 + padding
                let y = CGFloat(row) * (cardHeight + padding) + cardHeight/2 + padding
                
                annotation.corkboardX = Double(x)
                annotation.corkboardY = Double(y)
                didUpdate = true
                
                col += 1
                if col > 4 {
                    col = 0
                    row += 1
                }
            }
        }
        
        if didUpdate {
            try? modelContext.save()
        }
        hasInitializedPositions = true
    }
}

struct IndexCardView: View {
    @ObservedObject var annotation: SDAnnotation
    let pdfs: [SDConvertedPDF]
    
    private var bookTitle: String {
        pdfs.first(where: { $0.id == annotation.pdfID })?.name ?? annotation.readwiseBookTitle ?? "Unknown Source"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Source Book & Pin
            HStack {
                Text(bookTitle)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(Color(hex: annotation.colorHex ?? "#FFD60A"))
                    .frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            
            // Highlight Text
            if let text = annotation.selectedText, !text.isEmpty {
                Text(text)
                    .font(.system(.body, design: .serif))
                    .foregroundColor(.primary)
                    .lineLimit(5)
            }
            
            // User Note
            if let note = annotation.noteText, !note.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(note)
                        .font(.callout)
                        .italic()
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .frame(width: 260, height: 180, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.15), radius: 6, y: 4)
        )
        // Subtle index card texture line
        .overlay(
            VStack {
                Rectangle()
                    .fill(Color.red.opacity(0.3))
                    .frame(height: 1)
                    .padding(.top, 36)
                Spacer()
            }
        )
    }
}

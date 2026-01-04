
import SwiftUI
import PDFKit

struct PageManagerView: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    @State private var images: [UIImage] = []
    @State private var selectedIndices: Set<Int> = []
    @State private var isLoading = true
    @State private var showingConfirmation = false
    
    // Adaptive grid layout
    let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    
    var body: some View {
        NavigationView {
            VStack {
                if isLoading {
                    VStack(spacing: 15) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Extracting pages for preview...")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(0..<images.count, id: \.self) { index in
                                ZStack(alignment: .topTrailing) {
                                    // Thumbnail
                                    Image(uiImage: images[index])
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: 140)
                                        .cornerRadius(8)
                                        .opacity(selectedIndices.contains(index) ? 0.5 : 1.0)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selectedIndices.contains(index) ? Color.red : Color.gray.opacity(0.2), lineWidth: selectedIndices.contains(index) ? 3 : 1)
                                        )
                                    
                                    // Checkmark overlay
                                    if selectedIndices.contains(index) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.red)
                                            .background(Circle().fill(Color.white))
                                            .offset(x: 5, y: -5)
                                    }
                                    
                                    // Page Number
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.7))
                                        .cornerRadius(4)
                                        .padding(4)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                }
                                .onTapGesture {
                                    toggleSelection(index)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Manage Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showingConfirmation = true
                    } label: {
                        Text("Delete (\(selectedIndices.count))")
                            .foregroundColor(selectedIndices.isEmpty ? .secondary : .red)
                    }
                    .disabled(selectedIndices.isEmpty)
                }
            }
            .task {
                await loadPages()
            }
            .alert("Delete \(selectedIndices.count) Pages?", isPresented: $showingConfirmation) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await conversionManager.deletePages(from: pdf, pagesToDelete: selectedIndices)
                            dismiss()
                        } catch {
                            print("Error deleting pages: \(error)")
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone. The selected pages will be permanently removed from the file.")
            }
        }
    }
    
    private func loadPages() async {
        // Use existing extraction logic to get thumbnails
        // Note: For very large PDFs, we might want to paginate this, but for now we load all
        if let extracted = try? await conversionManager.extractPDFImages(from: pdf.url, progressHandler: { _ in }) {
            await MainActor.run {
                self.images = extracted
                self.isLoading = false
            }
        }
    }
    
    private func toggleSelection(_ index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
    }
}

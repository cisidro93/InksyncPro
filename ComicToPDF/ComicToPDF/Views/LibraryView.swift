import SwiftUI

struct LibraryView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var conversionManager: ConversionManager
    
    // UI State
    @State private var showingDocumentPicker = false
    
    // Logic State
    @State private var fileToConvert: ConvertedPDF?
    @State private var showingConvertAlert = false
    @State private var readingPDF: ConvertedPDF?
    
    var body: some View {
        NavigationView {
            VStack {
                // Empty State
                if conversionManager.convertedPDFs.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Files Found")
                            .font(.headline)
                        
                        Button("Import File") {
                            showingDocumentPicker = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } 
                // Library List
                else {
                    List {
                        ForEach(conversionManager.convertedPDFs) { pdf in
                            HStack {
                                // 1. Tappable Area (Icon + Name)
                                HStack {
                                    Image(systemName: iconForType(pdf))
                                        .foregroundColor(colorForType(pdf))
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading) {
                                        Text(pdf.name)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text(pdf.formattedSize)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .contentShape(Rectangle()) // Makes empty space tappable
                                .onTapGesture {
                                    handleTap(on: pdf)
                                }
                                
                                Spacer()
                                
                                // 2. The Missing "..." Action Menu
                                PDFActionViews(pdf: pdf)
                                    .buttonStyle(BorderlessButtonStyle()) // Prevents row selection when tapping dots
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let pdf = conversionManager.convertedPDFs[index]
                                conversionManager.deletePDF(pdf)
                            }
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
                
                // Status Bar
                if let status = conversionManager.statusMessage {
                    HStack {
                        if conversionManager.isConverting {
                            ProgressView()
                                .padding(.trailing, 5)
                        }
                        Text(status)
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.2))
                    .cornerRadius(8)
                    .padding()
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingDocumentPicker = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            // 1. File Picker Sheet
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker(
                    onDocumentsPicked: { urls in
                        conversionManager.processImportedFiles(urls: urls)
                    },
                    onError: { error in
                        print("Picker Error: \(error)")
                    }
                )
            }
            // 2. Conversion Alert
            .alert("Convert Comic?", isPresented: $showingConvertAlert) {
                Button("Convert") {
                    if let pdf = fileToConvert {
                        Task {
                            await conversionManager.convertComic(pdf)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This file needs to be processed before you can read it.")
            }
            // 3. Reader (Full Screen)
            .fullScreenCover(item: $readingPDF) { pdf in
                ReaderView(fileURL: pdf.url)
            }
        }
    }
    
    // Helper: Logic for Taps
    func handleTap(on pdf: ConvertedPDF) {
        let ext = pdf.url.pathExtension.lowercased()
        
        // Ready to Read?
        if ["pdf", "epub"].contains(ext) {
            readingPDF = pdf
        } 
        // Needs Conversion?
        else {
            fileToConvert = pdf
            showingConvertAlert = true
        }
    }
    
    // Helpers: Icons
    func iconForType(_ pdf: ConvertedPDF) -> String {
        let ext = pdf.url.pathExtension.lowercased()
        if ext == "pdf" { return "doc.text.fill" }
        if ext == "epub" { return "book.fill" }
        return "archivebox.fill"
    }
    
    func colorForType(_ pdf: ConvertedPDF) -> Color {
        let ext = pdf.url.pathExtension.lowercased()
        if ext == "pdf" { return .red }
        if ext == "epub" { return .blue }
        return .orange
    }
}

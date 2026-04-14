import SwiftUI

struct TrimPagesView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let pdf: ConvertedPDF
    let selectedPages: Set<Int>
    
    // Percentages to trim off each side (0.0 - 0.20)
    @State private var topTrim: Double = 0.0
    @State private var bottomTrim: Double = 0.0
    @State private var leftTrim: Double = 0.0
    @State private var rightTrim: Double = 0.0
    
    @State private var isProcessing = false
    @State private var progress: Double = 0.0
    
    @State private var showingError = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Trim Edges")) {
                    Text("Remove white borders or scanning artifacts from selected pages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Top")
                        Slider(value: $topTrim, in: 0...0.20)
                        Text(String(format: "%.0f%%", topTrim * 100))
                    }
                    HStack {
                        Text("Bottom")
                        Slider(value: $bottomTrim, in: 0...0.20)
                        Text(String(format: "%.0f%%", bottomTrim * 100))
                    }
                    HStack {
                        Text("Left")
                        Slider(value: $leftTrim, in: 0...0.20)
                        Text(String(format: "%.0f%%", leftTrim * 100))
                    }
                    HStack {
                        Text("Right")
                        Slider(value: $rightTrim, in: 0...0.20)
                        Text(String(format: "%.0f%%", rightTrim * 100))
                    }
                    
                    Button("Reset") {
                        topTrim = 0; bottomTrim = 0; leftTrim = 0; rightTrim = 0
                    }
                }
                
                if isProcessing {
                    Section {
                        VStack {
                            ProgressView("Trimming...", value: progress, total: 1.0)
                        }
                    }
                }
            }
            .navigationTitle("Trim Pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply Trim") {
                        startTrimming()
                    }
                    .disabled(isProcessing || (topTrim == 0 && bottomTrim == 0 && leftTrim == 0 && rightTrim == 0))
                }
            }
            .alert("Trim Failed", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    func startTrimming() {
        isProcessing = true
        
        Task {
            do {
                try await conversionManager.trimPages(
                    from: pdf,
                    pageIndices: selectedPages,
                    trim: (top: topTrim, bottom: bottomTrim, left: leftTrim, right: rightTrim)
                )
                
                await MainActor.run {
                    isProcessing = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                    showingError = true
                    Logger.shared.log("Trim failed: \(error.localizedDescription)", category: "Editor", type: .error)
                }
            }
        }
    }
}

import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @State private var showingPreview = false
    @State private var estimatedSize: String = "Calculating..."
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("File Name")
                    Spacer()
                    Text(pdf.name).foregroundColor(.secondary)
                }
                HStack {
                    Text("File Size")
                    Spacer()
                    Text(pdf.formattedSize).foregroundColor(.secondary)
                }
            } header: {
                Text("Source Details")
            }
            
            Section {
                Toggle("Enable Panel Detection", isOn: $conversionManager.conversionSettings.enablePanelSplit)
                if conversionManager.conversionSettings.enablePanelSplit {
                    Picker("Mode", selection: $conversionManager.conversionSettings.epubSettings.panelDetectionMode) {
                        Text("Automatic").tag(PanelExtractor.ExtractionMode.automatic)
                        Text("Aggressive").tag(PanelExtractor.ExtractionMode.aggressive)
                        Text("Grid (2x2)").tag(PanelExtractor.ExtractionMode.grid)
                    }
                }
                
                Toggle("Grayscale", isOn: $conversionManager.conversionSettings.imageEnhancement.grayscale)
                Toggle("Manga Mode (RTL)", isOn: $conversionManager.conversionSettings.mangaMode)
            } header: {
                Text("Conversion Options") // ✅ Fix: Explicit Header Closure
            }
            
            Section {
                Button(action: {
                    Task {
                        await conversionManager.convertComic(pdf)
                    }
                }) {
                    if conversionManager.isConverting {
                        HStack {
                            ProgressView()
                            Text(conversionManager.processingStatus)
                        }
                    } else {
                        Text("Start Conversion")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            if let status = conversionManager.statusMessage {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Convert Comic")
    }
}

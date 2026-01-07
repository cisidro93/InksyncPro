import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    // Local State for this specific conversion job
    @State private var isMangaMode = false
    @State private var enablePanelDetection = true
    @State private var detectionMode: PanelExtractor.ExtractionMode = .automatic
    
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
            
            // ✅ Enterprise UI: Configure the Asset, not the App
            Section {
                Picker("Reading Direction", selection: $isMangaMode) {
                    Text("Left-to-Right (Western)").tag(false)
                    Text("Right-to-Left (Manga)").tag(true)
                }
                .pickerStyle(.segmented) // Nice visual toggle
                
                Toggle("Enable Panel Detection", isOn: $enablePanelDetection)
                
                if enablePanelDetection {
                    Picker("Detection Mode", selection: $detectionMode) {
                        Text("Automatic").tag(PanelExtractor.ExtractionMode.automatic)
                        Text("Aggressive").tag(PanelExtractor.ExtractionMode.aggressive)
                        Text("Grid (2x2)").tag(PanelExtractor.ExtractionMode.grid)
                    }
                }
                
                Toggle("Grayscale (E-Ink)", isOn: $conversionManager.conversionSettings.imageEnhancement.grayscale)
            } header: {
                Text("Conversion Options")
            } footer: {
                Text(isMangaMode ? "Panels will be ordered Right-to-Left." : "Panels will be ordered Left-to-Right.")
            }
            
            Section {
                Button(action: {
                    Task {
                        // Apply temporary UI overrides to settings
                        conversionManager.conversionSettings.enablePanelSplit = enablePanelDetection
                        conversionManager.conversionSettings.epubSettings.panelDetectionMode = detectionMode
                        
                        // Pass the specific direction
                        await conversionManager.convertComic(pdf, mangaMode: isMangaMode)
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
                            .bold()
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
        .onAppear {
            // Load defaults from global settings initially
            isMangaMode = conversionManager.conversionSettings.mangaMode
            enablePanelDetection = conversionManager.conversionSettings.enablePanelSplit
        }
    }
}

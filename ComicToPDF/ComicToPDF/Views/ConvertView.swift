import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    // Local State
    @State private var isMangaMode = false
    @State private var selectedMode: ConversionMode = .hybrid
    
    // Enum for the 3-Card UI
    enum ConversionMode: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case hybrid = "Guided View"
        case panels = "Panels Only"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .standard: return "doc.richtext"
            case .hybrid: return "rectangle.split.3x1"
            case .panels: return "rectangle.grid.2x2"
            }
        }
        
        var description: String {
            switch self {
            case .standard: return "Original layout. Best for tablets."
            case .hybrid: return "Full page + zoomed panels. Best for Kindle."
            case .panels: return "Zoomed panels only. Best for phones."
            }
        }
    }
    
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
            
            // ✅ PRO UI: 3-Card Selector
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Reading Experience")
                        .font(.headline)
                        .padding(.bottom, 5)
                    
                    ForEach(ConversionMode.allCases) { mode in
                        Button(action: {
                            selectedMode = mode
                            updateSettings(for: mode)
                        }) {
                            HStack(spacing: 15) {
                                Image(systemName: mode.icon)
                                    .font(.title2)
                                    .frame(width: 30)
                                    .foregroundColor(selectedMode == mode ? .white : .blue)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .font(.headline)
                                        .foregroundColor(selectedMode == mode ? .white : .primary)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundColor(selectedMode == mode ? .white.opacity(0.8) : .secondary)
                                }
                                Spacer()
                                if selectedMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.white)
                                }
                            }
                            .padding()
                            .background(selectedMode == mode ? Color.blue : Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedMode == mode ? Color.blue : Color.gray.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.vertical, 5)
            } header: {
                Text("Output Format")
            }
            
            // Layout Direction (Enterprise Toggle)
            Section {
                Picker("Reading Direction", selection: $isMangaMode) {
                    Text("Left-to-Right (Western)").tag(false)
                    Text("Right-to-Left (Manga)").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Layout")
            } footer: {
                Text(isMangaMode ? "Panels ordered Right-to-Left." : "Panels ordered Left-to-Right.")
            }
            
            Section {
                Button(action: {
                    Task {
                        // Ensure settings are synced before converting
                        updateSettings(for: selectedMode)
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
            // Load initial state from global defaults
            isMangaMode = conversionManager.conversionSettings.mangaMode
            
            // Reverse-engineer the mode from current settings
            if !conversionManager.conversionSettings.enablePanelSplit {
                selectedMode = .standard
            } else if conversionManager.conversionSettings.epubSettings.includeFullPage {
                selectedMode = .hybrid
            } else {
                selectedMode = .panels
            }
        }
    }
    
    // Helper to map UI Card -> Backend Booleans
    func updateSettings(for mode: ConversionMode) {
        switch mode {
        case .standard:
            conversionManager.conversionSettings.enablePanelSplit = false
        case .hybrid:
            conversionManager.conversionSettings.enablePanelSplit = true
            conversionManager.conversionSettings.epubSettings.includeFullPage = true
        case .panels:
            conversionManager.conversionSettings.enablePanelSplit = true
            conversionManager.conversionSettings.epubSettings.includeFullPage = false
        }
    }
}

import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF
    
    @State private var isMangaMode = false
    @State private var selectedMode: ConversionMode = .hybrid
    @State private var showingPreview = false
    
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
                HStack { Text("File Name"); Spacer(); Text(pdf.name).foregroundColor(.secondary) }
                HStack { Text("File Size"); Spacer(); Text(pdf.formattedSize).foregroundColor(.secondary) }
                Picker("Auto-Split", selection: $conversionManager.conversionSettings.splitMode) {
                    ForEach(FileSizeSplitMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } header: { Text("Source Details") }
            
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Reading Experience").font(.headline).padding(.bottom, 5)
                    ForEach(ConversionMode.allCases) { mode in
                        Button(action: { selectedMode = mode; updateSettings(for: mode) }) {
                            HStack(spacing: 15) {
                                Image(systemName: mode.icon).font(.title2).frame(width: 30)
                                    .foregroundColor(selectedMode == mode ? .white : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue).font(.headline)
                                        .foregroundColor(selectedMode == mode ? .white : .primary)
                                    Text(mode.description).font(.caption)
                                        .foregroundColor(selectedMode == mode ? .white.opacity(0.8) : .secondary)
                                }
                                Spacer()
                                if selectedMode == mode { Image(systemName: "checkmark.circle.fill").foregroundColor(.white) }
                            }
                            .padding()
                            .background(selectedMode == mode ? Color.blue : Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedMode == mode ? Color.blue : Color.gray.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(conversionManager.isConverting)
                        .opacity(conversionManager.isConverting ? 0.6 : 1.0)
                    }
                }
                .padding(.vertical, 5)
                
                // ✅ PREVIEW BUTTON
                if selectedMode != .standard {
                    Button(action: { showingPreview = true }) {
                        Label("Preview Panel Detection (Page 4)", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 5)
                }
                
            } header: { Text("Output Format") }
            
            Section {
                Picker("Reading Direction", selection: $isMangaMode) {
                    Text("Left-to-Right (Western)").tag(false)
                    Text("Right-to-Left (Manga)").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(conversionManager.isConverting)
            } header: { Text("Layout") } footer: {
                Text(isMangaMode ? "Panels ordered Right-to-Left." : "Panels ordered Left-to-Right.")
            }
            
            Section {
                if conversionManager.isConverting {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Processing...").font(.headline).foregroundColor(.blue)
                            Spacer()
                            Text("\(Int(conversionManager.conversionProgress * 100))%").font(.subheadline).foregroundColor(.secondary).monospacedDigit()
                        }
                        ProgressView(value: conversionManager.conversionProgress, total: 1.0).progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    }
                    .padding(.vertical, 10)
                } else {
                    Button(action: {
                        Task {
                            updateSettings(for: selectedMode)
                            await conversionManager.convertComic(pdf, mangaMode: isMangaMode)
                        }
                    }) {
                        Text("Start Conversion").frame(maxWidth: .infinity).foregroundColor(.blue).bold()
                    }
                }
            }
            
            if let status = conversionManager.statusMessage {
                Section {
                    Text(status).font(.caption).foregroundColor(status.contains("Error") ? .red : .secondary)
                }
            }
        }
        .navigationTitle("Convert Comic")
        .onAppear {
            isMangaMode = conversionManager.conversionSettings.mangaMode
            if !conversionManager.conversionSettings.enablePanelSplit { selectedMode = .standard }
            else if conversionManager.conversionSettings.epubSettings.includeFullPage { selectedMode = .hybrid }
            else { selectedMode = .panels }
        }
        .sheet(isPresented: $showingPreview) {
            // ✅ FIX: Default to Page 3 (4th page) for better panel check, fallback to 0 if short doc
            PanelEditorView(pdf: pdf, pageIndex: 3)
                .environmentObject(conversionManager)
        }
    }
    
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

import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @StateObject private var viewModel = ConversionViewModel()
    let pdf: ConvertedPDF

    var body: some View {
        Form {
            // MARK: - Source Details
            Section {
                HStack { Text("File Name"); Spacer(); Text(pdf.name).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) }
                HStack { Text("File Size"); Spacer(); Text(pdf.formattedSize).foregroundColor(.secondary) }
                Picker("Auto-Split", selection: $settingsManager.conversionSettings.splitMode) {
                    ForEach(FileSizeSplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
            } header: { Text("Source Details") }

            // MARK: - Output Target
            Section {
                Picker("Target Format", selection: $settingsManager.conversionSettings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Label(format.rawValue, systemImage: format.icon).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settingsManager.conversionSettings.outputFormat) { _, newFormat in
                    if newFormat != .epub {
                        viewModel.selectedPipeline = .standard
                        viewModel.applyPipeline(.standard, to: &settingsManager.conversionSettings)
                    }
                }
                
                Picker("Image Quality", selection: $settingsManager.conversionSettings.compressionQuality) {
                    ForEach(CompressionPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            } header: { Text("Output Format") }
            
            // MARK: - Hardware Optimization
            Section {
                Picker("Target Device", selection: $settingsManager.conversionSettings.targetDeviceProfile) {
                    ForEach(TargetDeviceProfile.allCases) { device in
                        Text(device.rawValue).tag(device)
                    }
                }
                .pickerStyle(.menu)
                
                Toggle("E-Ink High Contrast Filter", isOn: $settingsManager.conversionSettings.optimizeForDevice)
            } header: { Text("Hardware Optimization") } footer: {
                Text("Select your specific e-reader to perfectly scale images and prevent device lag. Enable the high contrast filter to maximize readability on grayscale e-ink displays.")
            }

            // MARK: - Export Pipeline
            if settingsManager.conversionSettings.outputFormat == .epub {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("EPUB Export Mode")
                            .font(.headline)
                            .padding(.bottom, 4)
                            .foregroundColor(.primary)

                        ForEach(OutputPipeline.allCases) { pipeline in
                            let isDisabled = viewModel.pipelineIsDisabled(pipeline, for: pdf, format: settingsManager.conversionSettings.outputFormat)
                            Button(action: {
                                if !isDisabled {
                                    viewModel.selectedPipeline = pipeline
                                    viewModel.applyPipeline(pipeline, to: &settingsManager.conversionSettings)
                                }
                            }) {
                                PipelineCardView(
                                    pipeline: pipeline,
                                    isDisabled: isDisabled,
                                    isSelected: viewModel.selectedPipeline == pipeline,
                                    viewModel: viewModel,
                                    currentFormat: settingsManager.conversionSettings.outputFormat
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(conversionManager.isConverting || isDisabled)
                            .opacity(isDisabled || conversionManager.isConverting ? 0.55 : 1.0)
                        }
                    }
                    .padding(.vertical, 4)

                    // Preview & Guide buttons
                    if viewModel.selectedPipeline == .proPanel {
                        VStack(spacing: 8) {
                            Button(action: { viewModel.showingPreview = true }) {
                                Label("Preview Panel Detection (Page 4)", systemImage: "eye")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { viewModel.showingCalibreGuide = true }) {
                                Label("How to Sideload to Kindle", systemImage: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.top, 4)
                    }

                } header: { Text("Output Format") }
            }

            // MARK: - Layout
            Section {
                Picker("Reading Direction", selection: $viewModel.isMangaMode) {
                    Text("Left-to-Right (Western)").tag(false)
                    Text("Right-to-Left (Manga)").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(conversionManager.isConverting)
            } header: { Text("Layout") } footer: {
                Text(viewModel.isMangaMode ? "Panels ordered Right-to-Left." : "Panels ordered Left-to-Right.")
            }

            // MARK: - Convert Button
            Section {
                Button(action: {
                    Task {
                        viewModel.applyPipeline(viewModel.selectedPipeline, to: &settingsManager.conversionSettings)
                        await conversionManager.convertComic(pdf, mangaMode: viewModel.isMangaMode)
                    }
                }) {
                    Text("Start Conversion").frame(maxWidth: .infinity).foregroundColor(.blue).bold()
                }
                .disabled(conversionManager.isConverting)
            }

            if let status = conversionManager.statusMessage {
                Section {
                    Text(status).font(.caption).foregroundColor(status.contains("Error") ? .red : .secondary)
                }
            }
        }
        .overlay(
            Group {
                if conversionManager.isConverting {
                    ImmersiveConversionOverlay(pdfName: pdf.name)
                        .transition(.opacity.animation(.easeInOut))
                }
            }
        )
        .navigationTitle("Convert Comic")
        .onAppear {
            if let explicitManga = pdf.metadata.isManga {
                viewModel.isMangaMode = explicitManga
            } else {
                // Smart Fallback Detection if no XML exists
                let lowerName = pdf.name.lowercased()
                if lowerName.contains("manga") || lowerName.contains("chapter") || lowerName.contains("ch.") || lowerName.contains("raw") {
                    viewModel.isMangaMode = true
                } else if lowerName.contains("issue") || lowerName.contains("comic") || lowerName.contains("marvel") || lowerName.contains("dc") {
                    viewModel.isMangaMode = false
                } else {
                    viewModel.isMangaMode = settingsManager.conversionSettings.mangaMode
                }
            }
            viewModel.selectedPipeline = settingsManager.conversionSettings.outputPipeline
        }
        .sheet(isPresented: $viewModel.showingPreview) {
            PrecisionCanvasView(pdf: pdf, pageIndex: .constant(3), totalCount: pdf.pageCount, conversionManager: conversionManager)
        }
        .sheet(isPresented: $viewModel.showingCalibreGuide) {
            CalibreGuideView()
        }
    }
}

// MARK: - MVVM UI Components

struct PipelineCardView: View {
    let pipeline: OutputPipeline
    let isDisabled: Bool
    let isSelected: Bool
    @ObservedObject var viewModel: ConversionViewModel
    let currentFormat: OutputFormat

    var body: some View {
        let cardColor: Color = isDisabled ? .gray : (isSelected ? viewModel.cardAccentColor(for: pipeline) : Color(UIColor.secondarySystemGroupedBackground))
        let textColor: Color = isSelected ? .white : (isDisabled ? .gray : .primary)
        let subtextColor: Color = isSelected ? .white.opacity(0.8) : (isDisabled ? .gray.opacity(0.7) : .secondary)

        HStack(spacing: 14) {
            Image(systemName: viewModel.pipelineIcon(for: pipeline))
                .font(.title2)
                .frame(width: 30)
                .foregroundColor(isDisabled ? .gray : (isSelected ? .white : viewModel.cardAccentColor(for: pipeline)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pipeline.rawValue).font(.headline).foregroundColor(textColor)
                    if pipeline == .proPanel {
                        if isDisabled {
                            if currentFormat != .epub {
                                PipelineBadge(label: "EPUB Only", color: .gray)
                            } else {
                                PipelineBadge(label: "Comics Only", color: .gray)
                            }
                        } else {
                            PipelineBadge(label: "Guided View", color: isSelected ? .purple.opacity(0.8) : .purple)
                        }
                    }
                }
                Text(viewModel.pipelineSubtitle(for: pipeline)).font(.caption).foregroundColor(subtextColor)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.white)
            }
        }
        .padding()
        .background(cardColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? viewModel.cardAccentColor(for: pipeline) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

struct PipelineBadge: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }
}

// MARK: - Calibre Sideload Guide View
struct CalibreGuideView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sideloading Panel View to Kindle")
                            .font(.title2.bold())
                        Text("Due to recent Kindle firmware updates (5.19.2+), standard USB transfers no longer process advanced EPUB features directly on the device. Follow these steps to ensure Panel View works flawlessly.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 10)
                    
                    guideStep(number: 1, title: "Install Calibre & KFX Plugin", description: "Download the free library manager 'Calibre' on your computer. Inside Calibre, go to Preferences -> Plugins -> Get new plugins, and install the 'KFX Output' plugin.", icon: "gearshape.2.fill")
                    
                    guideStep(number: 2, title: "Export to Computer", description: "Use the 'Export' button in Inksync Pro to save your translated EPUB to iCloud Drive, or Share it directly to your Mac.", icon: "macbook.and.iphone")
                    
                    guideStep(number: 3, title: "Convert to KFX", description: "Drag the EPUB into Calibre. Select the book, click 'Convert books', and set the top-right Output Format to 'KFX'. Click OK.", icon: "arrow.triangle.2.circlepath")
                    
                    guideStep(number: 4, title: "Send via USB", description: "Connect your Kindle via USB. In Calibre, click 'Send to device'. The KFX file will carry all Panel View metadata and render natively on your Kindle.", icon: "cable.connector")
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("Send-to-Kindle Warning").font(.headline)
                        }
                        Text("Do not use Amazon's 'Send-to-Kindle' email or web service for Panel View books. Amazon's cloud strictly strips out RegionMagnification (Panel View) metadata from personal documents.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                }
                .padding()
            }
            .navigationTitle("Kindle Delivery Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    @ViewBuilder
    private func guideStep(number: Int, title: String, description: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.1)).frame(width: 36, height: 36)
                Text("\(number)").font(.headline).foregroundColor(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: icon).foregroundColor(.secondary)
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

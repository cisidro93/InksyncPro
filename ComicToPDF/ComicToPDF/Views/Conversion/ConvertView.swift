import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let pdf: ConvertedPDF

    @State private var isMangaMode = false
    @State private var selectedPipeline: OutputPipeline = .standard
    @State private var showingPreview = false

    var body: some View {
        Form {
            // MARK: - Source Details
            Section {
                HStack { Text("File Name"); Spacer(); Text(pdf.name).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle) }
                HStack { Text("File Size"); Spacer(); Text(pdf.formattedSize).foregroundColor(.secondary) }
                Picker("Auto-Split", selection: $conversionManager.conversionSettings.splitMode) {
                    ForEach(FileSizeSplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
            } header: { Text("Source Details") }

            // MARK: - Target Format
            Section {
                Picker("Target Format", selection: $conversionManager.conversionSettings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Label(format.rawValue, systemImage: format.icon).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: conversionManager.conversionSettings.outputFormat) { newFormat in
                    if newFormat != .epub {
                        selectedPipeline = .standard
                        applyPipeline(.standard)
                    }
                }
            } header: { Text("Output Target") }

            // MARK: - Export Pipeline
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("EPUB Export Mode")
                        .font(.headline)
                        .padding(.bottom, 4)
                        .foregroundColor(conversionManager.conversionSettings.outputFormat == .epub ? .primary : .secondary)

                    ForEach(OutputPipeline.allCases) { pipeline in
                        let isDisabled = pipelineIsDisabled(pipeline)
                        Button(action: {
                            if !isDisabled {
                                selectedPipeline = pipeline
                                applyPipeline(pipeline)
                            }
                        }) {
                            pipelineCard(pipeline, isDisabled: isDisabled)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(conversionManager.isConverting || isDisabled)
                        .opacity(isDisabled || conversionManager.isConverting ? 0.55 : 1.0)
                    }
                }
                .padding(.vertical, 4)

                // Preview button — show for either panel pipeline
                if selectedPipeline == .proPanel {
                    Button(action: { showingPreview = true }) {
                        Label("Preview Panel Detection (Page 4)", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                }

            } header: { Text("Output Format") }

            // MARK: - Layout
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

            // MARK: - Convert Button
            Section {
                if conversionManager.isConverting {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Processing...").font(.headline).foregroundColor(.blue)
                            Spacer()
                            Text("\(Int(conversionManager.conversionProgress * 100))%")
                                .font(.subheadline).foregroundColor(.secondary).monospacedDigit()
                        }
                        ProgressView(value: conversionManager.conversionProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    }
                    .padding(.vertical, 10)
                } else {
                    Button(action: {
                        Task {
                            applyPipeline(selectedPipeline)
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
            selectedPipeline = conversionManager.conversionSettings.outputPipeline
        }
        .sheet(isPresented: $showingPreview) {
            PrecisionCanvasView(pdf: pdf, pageIndex: 3, conversionManager: conversionManager)
        }
    }

    // MARK: - Pipeline Card View

    @ViewBuilder
    private func pipelineCard(_ pipeline: OutputPipeline, isDisabled: Bool) -> some View {
        let isSelected = selectedPipeline == pipeline
        let cardColor: Color = isDisabled ? .gray : (isSelected ? cardAccentColor(pipeline) : Color(UIColor.secondarySystemGroupedBackground))
        let textColor: Color = isSelected ? .white : (isDisabled ? .gray : .primary)
        let subtextColor: Color = isSelected ? .white.opacity(0.8) : (isDisabled ? .gray.opacity(0.7) : .secondary)

        HStack(spacing: 14) {
            Image(systemName: pipelineIcon(pipeline))
                .font(.title2)
                .frame(width: 30)
                .foregroundColor(isDisabled ? .gray : (isSelected ? .white : cardAccentColor(pipeline)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pipeline.rawValue).font(.headline).foregroundColor(textColor)

                    if pipeline == .proPanel {
                        if isDisabled {
                            if conversionManager.conversionSettings.outputFormat != .epub {
                                badgePill("EPUB Only", color: .gray)
                            } else {
                                badgePill("Comics Only", color: .gray)
                            }
                        } else {
                            badgePill("Guided View", color: isSelected ? .purple.opacity(0.8) : .purple)
                        }
                    }
                }
                Text(pipelineSubtitle(pipeline)).font(.caption).foregroundColor(subtextColor)
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
                .stroke(isSelected ? cardAccentColor(pipeline) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func badgePill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2).bold()
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }

    // MARK: - Helpers

    private func pipelineIcon(_ pipeline: OutputPipeline) -> String {
        switch pipeline {
        case .standard: return "doc.richtext"
        case .proPanel: return "rectangle.split.3x1"
        }
    }

    private func cardAccentColor(_ pipeline: OutputPipeline) -> Color {
        switch pipeline {
        case .standard: return .blue
        case .proPanel: return .purple
        }
    }

    private func pipelineSubtitle(_ pipeline: OutputPipeline) -> String {
        switch pipeline {
        case .standard:
            return "EPUB · No panel zoom · Cloud-safe (OneDrive, Google Drive, Send-to-Kindle)"
        case .proPanel:
            return "EPUB · Full Amazon Panel View Support · Universal Compatibility"
        }
    }

    /// Books do not support Pro Panel, and Pro Panel is strictly an EPUB feature.
    private func pipelineIsDisabled(_ pipeline: OutputPipeline) -> Bool {
        if pipeline == .proPanel {
            if pdf.contentType == .book { return true }
            if conversionManager.conversionSettings.outputFormat != .epub { return true }
        }
        return false
    }

    private func applyPipeline(_ pipeline: OutputPipeline) {
        conversionManager.conversionSettings.outputPipeline = pipeline
        switch pipeline {
        case .standard:
            conversionManager.conversionSettings.enablePanelSplit = false
        case .proPanel:
            conversionManager.conversionSettings.enablePanelSplit = true
            conversionManager.conversionSettings.epubSettings.includeFullPage = true
        }
    }
}

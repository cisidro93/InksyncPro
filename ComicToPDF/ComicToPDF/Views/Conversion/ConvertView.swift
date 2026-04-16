import SwiftUI

// MARK: - ConvertView (Go Mode per-file conversion settings)

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @StateObject private var viewModel = ConversionViewModel()
    let pdf: ConvertedPDF

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // MARK: Source Details
                InkCard(header: "Source Details") {
                    InfoRow(label: "File Name", value: pdf.name)
                    Divider().overlay(Color.inkBorderSubtle)
                    InfoRow(label: "File Size", value: pdf.formattedSize)
                    Divider().overlay(Color.inkBorderSubtle)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Auto-Split")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                        Picker("", selection: $settingsManager.conversionSettings.splitMode) {
                            ForEach(FileSizeSplitMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // MARK: Output Format
                InkCard(header: "Output Format") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Format")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                        Picker("", selection: $settingsManager.conversionSettings.outputFormat) {
                            ForEach(OutputFormat.allCases) { format in
                                Label(format.rawValue, systemImage: format.icon).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: settingsManager.conversionSettings.outputFormat) { _, newFormat in
                            if newFormat != .epub {
                                viewModel.selectedPipeline = .standard
                                viewModel.applyPipeline(.standard, to: &settingsManager.conversionSettings)
                            }
                        }
                    }
                    Divider().overlay(Color.inkBorderSubtle)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Image Quality")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                        Picker("", selection: $settingsManager.conversionSettings.compressionQuality) {
                            ForEach(CompressionPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // MARK: Hardware Optimisation
                InkCard(header: "Hardware Optimisation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Device")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                        Picker("", selection: $settingsManager.conversionSettings.targetDeviceProfile) {
                            ForEach(TargetDeviceProfile.allCases) { device in
                                Text(device.rawValue).tag(device)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.inkBlue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.inkSurfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Divider().overlay(Color.inkBorderSubtle)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("E-Ink High Contrast Filter")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.inkTextPrimary)
                            Text("Maximises readability on greyscale e-ink displays")
                                .font(.system(size: 12))
                                .foregroundColor(.inkTextSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settingsManager.conversionSettings.optimizeForDevice)
                            .labelsHidden()
                            .tint(.inkBlue)
                    }
                }

                // MARK: Export Pipeline (EPUB only)
                if settingsManager.conversionSettings.outputFormat == .epub {
                    InkCard(header: "EPUB Export Mode") {
                        VStack(spacing: 10) {
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

                            if viewModel.selectedPipeline == .proPanel {
                                VStack(spacing: 8) {
                                    Button(action: { viewModel.showingPreview = true }) {
                                        Label("Preview Panel Detection (Page 4)", systemImage: "eye")
                                            .font(.system(size: 14))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.inkSurfaceRaised)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .foregroundColor(.inkTextPrimary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    Button(action: { viewModel.showingCalibreGuide = true }) {
                                        Label("How to Sideload to Kindle", systemImage: "questionmark.circle")
                                            .font(.caption)
                                            .foregroundColor(.inkBlue)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }

                // MARK: Layout / Reading Direction
                InkCard(header: "Layout") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading Direction")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.inkTextPrimary)
                            Text(viewModel.isMangaMode ? "Right to Left (Manga)" : "Left to Right (Western)")
                                .font(.system(size: 12))
                                .foregroundColor(.inkTextSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.isMangaMode)
                            .labelsHidden()
                            .tint(.inkBlue)
                            .disabled(conversionManager.isConverting)
                    }
                }

                // MARK: Status Message
                if let status = conversionManager.statusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: status.contains("Error") ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundColor(status.contains("Error") ? .inkRed : .inkBlue)
                        Text(status)
                            .font(.caption)
                            .foregroundColor(status.contains("Error") ? .inkRed : .inkTextSecondary)
                        Spacer()
                    }
                    .padding(12)
                    .background(status.contains("Error") ? Color.inkRed.opacity(0.08) : Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // MARK: Primary CTA
                Button(action: {
                    Task {
                        viewModel.applyPipeline(viewModel.selectedPipeline, to: &settingsManager.conversionSettings)
                        await conversionManager.convertComic(pdf, mangaMode: viewModel.isMangaMode)
                    }
                }) {
                    HStack(spacing: 10) {
                        if conversionManager.isConverting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text(conversionManager.isConverting ? "Converting…" : "Start Conversion")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(conversionManager.isConverting ? Color.inkTextTertiary : Color.inkBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .animation(.easeInOut(duration: 0.2), value: conversionManager.isConverting)
                }
                .disabled(conversionManager.isConverting)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color.inkBackground.ignoresSafeArea())
        // ✅ #7: Show the actual filename, not a generic title
        .navigationTitle(pdf.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(
            Group {
                if conversionManager.isConverting {
                    ImmersiveConversionOverlay(pdfName: pdf.name)
                        .transition(.opacity.animation(.easeInOut))
                }
            }
        )
        .onAppear {
            if let explicitManga = pdf.metadata.isManga {
                viewModel.isMangaMode = explicitManga
            } else {
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

// MARK: - InkCard: shared section container for Go Mode

struct InkCard<Content: View>: View {
    let header: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(header.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.inkTextSecondary)
                .padding(.bottom, 2)

            content()
        }
        .padding(16)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.inkBorderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - InfoRow: label/value pair

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.inkTextPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.inkTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - MVVM UI Components (Pipeline cards — unchanged)

struct PipelineCardView: View {
    let pipeline: OutputPipeline
    let isDisabled: Bool
    let isSelected: Bool
    @ObservedObject var viewModel: ConversionViewModel
    let currentFormat: OutputFormat

    var body: some View {
        let cardColor: Color = isDisabled ? .gray : (isSelected ? viewModel.cardAccentColor(for: pipeline) : Color.inkSurfaceRaised)
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
                .stroke(isSelected ? viewModel.cardAccentColor(for: pipeline) : Color.inkBorderSubtle, lineWidth: isSelected ? 1.5 : 0.5)
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
        NavigationStack {
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

                    guideStep(number: 1, title: "Install Calibre & KFX Plugin", description: "Download the free library manager 'Calibre' on your computer. Inside Calibre, go to Preferences → Plugins → Get new plugins, and install the 'KFX Output' plugin.", icon: "gearshape.2.fill")
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

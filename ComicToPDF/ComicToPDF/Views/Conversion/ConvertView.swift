import SwiftUI

// MARK: - ConvertView (Go Mode per-file conversion settings)

struct ConvertView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @StateObject private var viewModel = ConversionViewModel()
    @State private var showingQualityPreviewModal = false
    let pdf: ConvertedPDF

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // MARK: Output Metadata
                outputMetadataSection(libraryFiles: conversionManager.libraryFiles)

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Image Quality & Compression")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                        
                        Picker("", selection: $settingsManager.conversionSettings.compressionQuality) {
                            ForEach(CompressionPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.inkBlue)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.inkSurfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        if settingsManager.conversionSettings.compressionQuality == .customTarget {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Target File Size Limit")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text("\(Int(settingsManager.conversionSettings.targetFileSizeMB)) MB")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.inkBlue)
                                }
                                
                                HStack(spacing: 8) {
                                    ForEach([50.0, 100.0, 250.0, 500.0], id: \.self) { mb in
                                        Button {
                                            HapticEngine.light()
                                            settingsManager.conversionSettings.targetFileSizeMB = mb
                                        } label: {
                                            Text("\(Int(mb))MB")
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(settingsManager.conversionSettings.targetFileSizeMB == mb ? Color.inkBlue : Color.inkSurfaceRaised)
                                                .foregroundColor(settingsManager.conversionSettings.targetFileSizeMB == mb ? .white : .primary)
                                                .cornerRadius(6)
                                        }
                                    }
                                }
                                
                                Slider(value: $settingsManager.conversionSettings.targetFileSizeMB, in: 10...1000, step: 10)
                                    .tint(.inkBlue)
                            }
                            .padding(10)
                            .background(Color.inkSurfaceRaised.opacity(0.5))
                            .cornerRadius(8)
                        }
                        
                        Button {
                            HapticEngine.medium()
                            showingQualityPreviewModal = true
                        } label: {
                            HStack {
                                Image(systemName: "eye.trianglebadge.exclamationmark")
                                Text("Live Quality & Compression Preview")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.inkBlue.opacity(0.12))
                            .foregroundColor(.inkBlue)
                            .cornerRadius(8)
                        }
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

                // MARK: Export Pipeline
                InkCard(header: "Conversion Mode") {
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
                    Divider().overlay(Color.inkBorderSubtle)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link Cover Page as Spread")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.inkTextPrimary)
                            Text("Pairs Cover Page with Page 2 as a spread")
                                .font(.system(size: 12))
                                .foregroundColor(.inkTextSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settingsManager.conversionSettings.linkCoverAsSpread)
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
                        await conversionManager.convertComic(pdf, mangaMode: viewModel.isMangaMode, customOutputName: viewModel.targetFilename)
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
        .background(Color.clear.ignoresSafeArea())
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
            
            var derived = pdf.name
            while derived.contains(".") {
                let stripped = (derived as NSString).deletingPathExtension
                if stripped == derived { break }
                derived = stripped
            }
            viewModel.targetFilename = derived
            if let author = pdf.metadata.author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                viewModel.targetAuthor = author
            } else {
                let fileURL = pdf.url
                Task.detached(priority: .userInitiated) {
                    if let comicInfo = ComicInfoParser.parse(from: fileURL), let writer = comicInfo.writer, !writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            viewModel.targetAuthor = writer
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showingPreview) {
            PrecisionCanvasView(pdf: pdf, pageIndex: .constant(3), totalCount: pdf.pageCount, conversionManager: conversionManager)
        }
        .sheet(isPresented: $viewModel.showingCalibreGuide) {
            CalibreGuideView()
        }
        .sheet(isPresented: $showingQualityPreviewModal) {
            QualityPreviewModalView(
                settings: $settingsManager.conversionSettings,
                sampleImage: UIImage(contentsOfFile: pdf.url.path),
                fileTitle: pdf.name,
                totalPageCount: pdf.pageCount,
                totalInputSizeBytes: pdf.fileSize
            )
        }
        .onChange(of: conversionManager.isConverting) { isConverting in
            if !isConverting {
                let status = conversionManager.statusMessage ?? ""
                if !status.contains("Error") {
                    dismiss()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkTabGoToLibraryRoot)) { _ in
            dismiss()
        }
    }

    @ViewBuilder
    private func outputMetadataSection(libraryFiles: [ConvertedPDF]) -> some View {
        let authors = filteredAuthors(from: libraryFiles)
        InkCard(header: "Output Metadata") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output Title")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                    HStack(spacing: 8) {
                        TextField("Enter filename", text: $viewModel.targetFilename)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 14))
                            .padding(10)
                            .background(Color.inkSurfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
                            )
                            .disabled(conversionManager.isConverting)
                        
                        Text(".\(settingsManager.conversionSettings.outputFormat.rawValue)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.inkTextSecondary)
                    }
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Author / Writer")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                    TextField("Enter author name (e.g. Eiichiro Oda)", text: $viewModel.targetAuthor)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 14))
                        .padding(10)
                        .background(Color.inkSurfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.inkBorderSubtle, lineWidth: 1)
                        )
                        .disabled(conversionManager.isConverting)
                    
                    if !authors.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Text("Library Authors:")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.inkTextSecondary)
                                
                                ForEach(authors, id: \.self) { authorName in
                                    Button {
                                        HapticEngine.light()
                                        viewModel.targetAuthor = authorName
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 9))
                                            Text(authorName)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.inkBlue.opacity(0.12))
                                        .foregroundColor(.inkBlue)
                                        .cornerRadius(6)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private func filteredAuthors(from files: [ConvertedPDF]) -> [String] {
        let rawList = files.compactMap { $0.metadata.author?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
        let known = Array(Set(rawList.filter { !$0.isEmpty })).sorted()
        let typed = viewModel.targetAuthor.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if typed.isEmpty {
            return Array(known.prefix(6))
        } else {
            return Array(known.filter { $0.localizedCaseInsensitiveContains(typed) && $0 != typed }.prefix(6))
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
        .background(Color.inkSurface.opacity(0.4))
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
                    Text(pipeline.displayName).font(.headline).foregroundColor(textColor)
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
                Text(viewModel.pipelineSubtitle(for: pipeline, format: currentFormat)).font(.caption).foregroundColor(subtextColor)
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
                        Text("Sideloading to Kindle & E-Readers")
                            .font(.title2.bold())
                        Text("Follow these steps to transfer your converted books to your Kindle or other e-readers using Calibre.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 10)

                    guideStep(number: 1, title: "Install Calibre", description: "Download the free library manager 'Calibre' on your computer.", icon: "gearshape.2.fill")
                    guideStep(number: 2, title: "Export to Computer", description: "Use the 'Export' button in Inksync Pro to save your translated EPUB to iCloud Drive, or Share it directly to your Mac.", icon: "macbook.and.iphone")
                    guideStep(number: 3, title: "Add to Calibre", description: "Drag the EPUB file into your Calibre library interface.", icon: "arrow.triangle.2.circlepath")
                    guideStep(number: 4, title: "Send via USB", description: "Connect your Kindle or e-reader via USB. In Calibre, click 'Send to device' to copy it directly to your device.", icon: "cable.connector")

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
            .background(Color.clear)
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
        .background(Color.inkSurface.opacity(0.4))
        .cornerRadius(12)
    }
}

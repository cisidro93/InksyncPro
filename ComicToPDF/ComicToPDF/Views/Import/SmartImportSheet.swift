import SwiftUI

@MainActor
class SmartImportViewModel: ObservableObject {
    let sourceURL: URL
    @Published var title: String = ""
    @Published var seriesName: String = ""
    @Published var volumeNumber: String = ""
    @Published var isManga: Bool = false
    @Published var detectedIsManga: Bool = false
    @Published var destinationDevice: RegisteredDevice?
    @Published var flaggedPageIndices: [Int] = []
    @Published var overallConfidence: Double = 0.0
    @Published var isAnalysing: Bool = true
    @Published var seriesMemory: SeriesMemory? = nil
    @Published var showAdvanced: Bool = false
    @Published var selectedPipeline: OutputPipeline = .standard
    @Published var userEditedTitle: Bool = false
    @Published var userEditedDirection: Bool = false
    @Published var pageCount: Int = 0

    var canSkipSheet: Bool { seriesMemory?.canSkipImportSheet == true }
    var shouldShowPanelStrip: Bool {
        !flaggedPageIndices.isEmpty && seriesMemory?.canSuppressPanelReview != true
    }
    var destinationDescription: String {
        guard let d = destinationDevice else { return "No device configured" }
        return "Ready for \(d.name)"
    }

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func analyse(manager: ConversionManager) async {
        // 1. Display name from LocalComicInfoService
        if let xml = try? LocalComicInfoService.shared.fetchNonDestructiveMetadata(from: sourceURL) {
            title = xml.displayName
        } else {
            title = (sourceURL.lastPathComponent as NSString).deletingPathExtension
        }

        // 2. Full metadata from ComicInfoParser
        if let parsed = ComicInfoParser.parse(from: sourceURL) {
            seriesName = parsed.series ?? SeriesNameDetector.detect(from: sourceURL.lastPathComponent).seriesName
            volumeNumber = parsed.number ?? ""
            isManga = parsed.manga
            detectedIsManga = parsed.manga
            if !seriesName.isEmpty { title = parsed.title ?? title }
        } else {
            let detected = SeriesNameDetector.detect(from: sourceURL.lastPathComponent)
            seriesName = detected.seriesName
            volumeNumber = detected.issueNumber.map(String.init) ?? ""
        }

        // 3. Series memory
        if !seriesName.isEmpty {
            seriesMemory = SeriesMemoryStore.shared.memory(for: seriesName)
            if let mem = seriesMemory {
                isManga = mem.confirmedMangaRTL ?? isManga
                if let devID = mem.lastDeviceID {
                    destinationDevice = manager.registeredDevices.first { $0.id == devID }
                }
            }
        }

        // 4. Destination device fallback
        if destinationDevice == nil { destinationDevice = manager.primaryDevice }

        // 5. Lightweight panel scan (first 15 pages only)
        if let extraction = try? await ZipUtilities.extractComic(from: sourceURL) {
            let sample = Array(extraction.imageURLs.prefix(15))
            pageCount = extraction.imageURLs.count
            var confidences: [Double] = []
            for url in sample {
                if let img = UIImage(contentsOfFile: url.path) {
                    let panels = await PanelExtractor.detectPanels(
                        in: img, mode: .automatic, mangaMode: isManga
                    )
                    let conf = panels.isEmpty ? 0.5 : Double(panels.count) / 10.0
                    confidences.append(min(conf, 1.0))
                }
            }
            overallConfidence = confidences.isEmpty ? 0.8 : confidences.reduce(0, +) / Double(confidences.count)
            try? FileManager.default.removeItem(at: extraction.workingDir)
        }

        isAnalysing = false
    }

    func confirm(manager: ConversionManager) {
        // Apply pipeline to settings
        ConversionViewModel().applyPipeline(selectedPipeline, to: &manager.conversionSettings)
        manager.conversionSettings.mangaMode = isManga

        // Record to series memory
        SeriesMemoryStore.shared.record(
            seriesName: seriesName,
            deviceID: destinationDevice?.id,
            isManga: isManga,
            panelConfidence: overallConfidence,
            editedPanels: false,
            editedMetadata: userEditedTitle || userEditedDirection
        )

        // Route through ImportOrchestrator via processImportedFiles
        Task {
            await manager.processImportedFiles(urls: [sourceURL])
        }
    }
}

struct SmartImportSheet: View {
    let sourceURL: URL
    @StateObject private var vm: SmartImportViewModel
    @EnvironmentObject var manager: ConversionManager
    @Environment(\.dismiss) var dismiss

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        _vm = StateObject(wrappedValue: SmartImportViewModel(sourceURL: sourceURL))
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                if vm.isAnalysing {
                    AnalysingView()
                } else if vm.canSkipSheet {
                    SkippedImportView(vm: vm) {
                        vm.confirm(manager: manager)
                        dismiss()
                    } onChange: {
                        // Don't skip, show full sheet
                        vm.seriesMemory = nil
                    }
                } else {
                    ImportFormView(vm: vm) {
                        vm.confirm(manager: manager)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Add to Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.inkTextSecondary)
                }
            }
        }
        .task { await vm.analyse(manager: manager) }
    }
}

// MARK: - Import Form (full sheet for new/unknown series)
struct ImportFormView: View {
    @ObservedObject var vm: SmartImportViewModel
    let onConfirm: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Cover + title area
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.inkSurfaceRaised)
                        .frame(width: 64, height: 90)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .foregroundColor(.inkTextSecondary)
                        )

                    Text(vm.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.inkTextPrimary)
                }
                .padding(.top, 20)

                // Smart fields
                VStack(spacing: 10) {
                    SmartFieldRow(label: "Series", value: vm.seriesName, confirmed: true)
                    SmartFieldRow(label: "Volume", value: vm.volumeNumber.isEmpty ? "—" : vm.volumeNumber, confirmed: false)

                    // Direction toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reading Direction")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.inkTextSecondary)
                            Text(vm.isManga ? "Right to Left" : "Left to Right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(vm.detectedIsManga ? .inkGreen : .inkTextPrimary)
                        }
                        Spacer()
                        if vm.detectedIsManga {
                            Text("Auto-detected")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.inkGreen)
                        }
                        Toggle("", isOn: $vm.isManga)
                            .tint(.inkBlue)
                            .labelsHidden()
                            .onChange(of: vm.isManga) { _ in
                                vm.userEditedDirection = true
                            }
                    }
                    .padding(12)
                    .background(Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Destination
                    HStack {
                        Image(systemName: vm.destinationDevice?.deviceType.sfSymbol ?? "questionmark.circle")
                            .foregroundColor(.inkBlue)
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sending to")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.inkTextSecondary)
                            Text(vm.destinationDevice?.name ?? "No device — tap to add")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.inkTextPrimary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 20)

                // Auto-config note
                if vm.destinationDevice != nil {
                    Text(vm.destinationDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.inkBlue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.inkBlue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 20)
                }

                // Panel strip (conditional)
                if vm.shouldShowPanelStrip {
                    PageFlagStrip(
                        flaggedIndices: vm.flaggedPageIndices,
                        totalPages: vm.pageCount
                    )
                    .padding(.horizontal, 20)
                }

                // Advanced disclosure
                DisclosureGroup("Advanced options", isExpanded: $vm.showAdvanced) {
                    PipelineSelector(selectedPipeline: $vm.selectedPipeline, pdf: nil)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .foregroundColor(.inkTextSecondary)

                // Actions
                VStack(spacing: 8) {
                    Button(action: onConfirm) {
                        Text("Add to Library →")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.inkBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button("Advanced Convert Settings") {
                        // For a future deep integration with ConvertView
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.inkTextSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}

// MARK: - Skipped Import (3rd+ time, known series)
struct SkippedImportView: View {
    @ObservedObject var vm: SmartImportViewModel
    let onConfirm: () -> Void
    let onChange: () -> Void
    @State private var countdown: Int = 3
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.inkGreen)

            VStack(spacing: 6) {
                Text("Converting as usual")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.inkTextPrimary)
                Text("\(vm.seriesName) · \(vm.destinationDevice?.name ?? "device")")
                    .font(.system(size: 14))
                    .foregroundColor(.inkTextSecondary)
            }

            // Settings recap pills
            HStack(spacing: 8) {
                let settings = [
                    vm.isManga ? "Manga RTL" : "LTR",
                    vm.destinationDevice?.deviceType.rawValue ?? "",
                    "Auto quality"
                ].filter { !$0.isEmpty }

                ForEach(settings, id: \.self) { setting in
                    Text(setting)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.inkSurfaceRaised)
                        .clipShape(Capsule())
                }
            }

            Text("Starting in \(countdown)…")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.inkTextTertiary)

            Spacer()

            Button("Change settings") { onChange() }
                .font(.system(size: 14))
                .foregroundColor(.inkTextSecondary)
                .padding(.bottom, 30)
        }
        .onReceive(timer) { _ in
            if countdown > 1 { countdown -= 1 }
            else { onConfirm() }
        }
    }
}

// MARK: - Spinner Subview
struct AnalysingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.inkBlue)
                .scaleEffect(1.5)
            Text("Analysing content...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.inkTextSecondary)
        }
    }
}

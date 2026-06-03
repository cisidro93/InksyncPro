import SwiftUI
import SwiftData

@MainActor
class SmartImportViewModel: ObservableObject {
    let sourceURL: URL
    @Published var title: String = ""
    @Published var seriesName: String = ""
    @Published var volumeNumber: String = ""
    @Published var isManga: Bool = false
    @Published var detectedIsManga: Bool = false
    @Published var destinationDevice: SDRegisteredDevice?
    @Published var flaggedPageIndices: [Int] = []
    @Published var overallConfidence: Double = 0.0
    @Published var isAnalysing: Bool = true
    @Published var extractionError: String? = nil
    @Published var seriesMemory: SDSeriesMemory? = nil
    @Published var showAdvanced: Bool = false
    @Published var selectedPipeline: OutputPipeline = .standard
    @Published var userEditedTitle: Bool = false
    @Published var userEditedDirection: Bool = false
    @Published var pageCount: Int = 0
    @Published var firstPageURL: URL? = nil  // for live cover preview

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

    func analyse(savedDevices: [SDRegisteredDevice], primaryDeviceID: UUID?, context: ModelContext) async {
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

        // 3. Series memory (SwiftData fetch)
        if !seriesName.isEmpty {
            let normalized = seriesName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let fetch = FetchDescriptor<SDSeriesMemory>(predicate: #Predicate { $0.seriesNameNormalized == normalized })
            if let mem = try? context.fetch(fetch).first {
                self.seriesMemory = mem
                isManga = mem.confirmedMangaRTL ?? isManga
                if let devID = mem.lastDeviceID {
                    destinationDevice = savedDevices.first { $0.id == devID }
                }
            }
        }

        // 4. Destination device fallback
        if destinationDevice == nil { 
            if let primaryID = primaryDeviceID, let primary = savedDevices.first(where: { $0.id == primaryID }) {
                destinationDevice = primary
            } else {
                destinationDevice = savedDevices.first
            }
        }

        // 5. Panel scan — MUST run off the MainActor.
        // UIImage(contentsOfFile:) synchronously decodes the full uncompressed bitmap
        // for each page (manga pages can be 30–100 MB each uncompressed). Loading 15
        // of them on the main actor: (a) blocks the UI thread → iOS watchdog crash,
        // (b) creates 450MB+ peak RAM on the main stack → OOM kill.
        // Solution: run the entire scan in Task.detached; write only the final
        // aggregated values back to @MainActor properties.
        do {
            // Security scope MUST be opened here before calling into ZipUtilities.
            // Document-picker URLs are security-scoped: without opening the scope,
            // ZIPFoundation receives EACCES and CBRExtractor/libunrar receives
            // ERAR_EOPEN, both of which crash or silently fail on a single-file import.
            let secured = sourceURL.startAccessingSecurityScopedResource()
            // Hold scope open for the full duration of the extraction call.
            // Do NOT defer-close it before the continuation resumes — that would
            // drop the ref-count to zero mid-read and produce ERAR_EOPEN on CBR.
            let extraction = try await ZipUtilities.extractComic(from: sourceURL)
            if secured { sourceURL.stopAccessingSecurityScopedResource() }

            let allImages = extraction.imageURLs
            let workingDir = extraction.workingDir

            await MainActor.run {
                pageCount = allImages.count
                firstPageURL = allImages.first
            }

            let sample = Array(allImages.prefix(15))
            let capturedIsManga = isManga

            // Run image decode + panel detection entirely off the main thread
            let averageConfidence: Double = await Task.detached(priority: .userInitiated) {
                var confidences: [Double] = []
                for url in sample {
                    // Load the image synchronously — autoreleasepool frees the decoded
                    // bitmap buffer once detection is complete for each page.
                    // UIImage reference must survive outside autoreleasepool for the await.
                    var img: UIImage?
                    autoreleasepool { img = UIImage(contentsOfFile: url.path) }
                    guard let image = img else { continue }
                    // PanelExtractor.detectPanels is async but nonisolated — safe off main actor
                    let panels = await PanelExtractor.detectPanels(
                        in: image, mode: .automatic, mangaMode: capturedIsManga
                    )
                    let conf = panels.isEmpty ? 0.5 : min(Double(panels.count) / 10.0, 1.0)
                    confidences.append(conf)
                }
                return confidences.isEmpty ? 0.8 : confidences.reduce(0, +) / Double(confidences.count)
            }.value

            await MainActor.run { overallConfidence = averageConfidence }

            // Keep only the cover image for live preview; clean up the rest.
            // workingDir must be removed entirely — deleting individual files leaves
            // the directory and its subdirectories on disk permanently (storage leak).
            if let coverURL = allImages.first {
                // Move cover to an independent temp file so it survives workingDir deletion.
                let coverCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cover_preview_\(UUID().uuidString).\(coverURL.pathExtension)")
                try? FileManager.default.copyItem(at: coverURL, to: coverCopy)
                await MainActor.run { firstPageURL = coverCopy }
            }
            // Now safe to nuke the entire extraction directory.
            try? FileManager.default.removeItem(at: workingDir)
        } catch {
            self.extractionError = "Could not validate comic archive. The volume may be corrupted or encrypted: \(error.localizedDescription)"
        }

        isAnalysing = false
    }

    func confirm(manager: ConversionManager, context: ModelContext) {
        HapticEngine.success()  // import confirmed
        // Apply pipeline to settings
        ConversionViewModel().applyPipeline(selectedPipeline, to: &AppSettingsManager.shared.conversionSettings)
        AppSettingsManager.shared.conversionSettings.mangaMode = isManga

        // Record to SwiftData
        let normalized = seriesName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let fetch = FetchDescriptor<SDSeriesMemory>(predicate: #Predicate { $0.seriesNameNormalized == normalized })
        let m = (try? context.fetch(fetch).first) ?? SDSeriesMemory(seriesNameNormalized: normalized)
        
        m.conversionCount += 1
        m.lastDeviceID = destinationDevice?.id
        m.confirmedMangaRTL = isManga
        if let e = m.averagePanelConfidence { m.averagePanelConfidence = (e + overallConfidence) / 2 }
        else { m.averagePanelConfidence = overallConfidence }
        if userEditedTitle || userEditedDirection { m.hasUserEverEditedMetadata = true }
        // Note: editedPanels is injected upstream via PageModelStore on edits
        
        context.insert(m)
        try? context.save()

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
    @Environment(\.modelContext) private var context
    
    @Query private var savedDevices: [SDRegisteredDevice]

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        _vm = StateObject(wrappedValue: SmartImportViewModel(sourceURL: sourceURL))
    }
    
    @State private var showingConvertSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                if vm.isAnalysing {
                    AnalysingView(seriesName: vm.sourceURL.deletingPathExtension().lastPathComponent)
                } else if vm.canSkipSheet {
                    SkippedImportView(vm: vm) {
                        vm.confirm(manager: manager, context: context)
                        dismiss()
                    } onChange: {
                        // Don't skip, show full sheet
                        vm.seriesMemory = nil
                    }
                } else {
                    ImportFormView(vm: vm, showingConvertSettings: $showingConvertSettings) {
                        vm.confirm(manager: manager, context: context)
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
        .task { await vm.analyse(savedDevices: savedDevices, primaryDeviceID: DeviceRegistry.shared.primaryDeviceID, context: context) }
        .alert("Import Failed", isPresented: Binding(
            get: { vm.extractionError != nil },
            set: { if !$0 { dismiss() } }
        )) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text(vm.extractionError ?? "Archive is corrupted or invalid.")
        }
        // QoL: Wire Advanced Settings to full ConvertView
        .sheet(isPresented: $showingConvertSettings) {
            NavigationStack {
                ConvertView(pdf: ConvertedPDF(
                    name: vm.title,
                    url: sourceURL,
                    pageCount: vm.pageCount,
                    fileSize: (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0,
                    metadata: PDFMetadata(
                        title: vm.title,
                        series: vm.seriesName.isEmpty ? nil : vm.seriesName,
                        issueNumber: vm.volumeNumber.isEmpty ? nil : vm.volumeNumber
                    )
                ))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingConvertSettings = false }
                    }
                }
            }
        }
    }
}

// MARK: - Import Form (full sheet for new/unknown series)
struct ImportFormView: View {
    @ObservedObject var vm: SmartImportViewModel
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Binding var showingConvertSettings: Bool
    let onConfirm: () -> Void

    var body: some View {
        if hSizeClass == .regular {
            iPadImportForm
        } else {
            iPhoneImportForm
        }
    }

    private var iPhoneImportForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Cover + title area
                VStack(spacing: 8) {
                // Cover preview — show actual first page if available
                Group {
                    if let coverURL = vm.firstPageURL,
                       let img = UIImage(contentsOfFile: coverURL.path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 4)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.inkSurfaceRaised)
                            .frame(width: 64, height: 90)
                            .overlay(Image(systemName: "book.closed.fill").foregroundColor(.inkTextSecondary))
                    }
                }

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
                    directionToggle
                        .padding(12)
                        .background(Color.inkSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Destination
                    deviceSelector
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
                        showingConvertSettings = true
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.inkTextSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }

    private var iPadImportForm: some View {
        HStack(alignment: .top, spacing: 40) {
            // Left column — cover + series info
            VStack(spacing: 16) {
                // Cover (larger on iPad)
                // Cover preview — larger on iPad
                Group {
                    if let coverURL = vm.firstPageURL,
                       let img = UIImage(contentsOfFile: coverURL.path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(radius: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.inkSurfaceRaised)
                            .frame(width: 120, height: 170)
                            .overlay(Image(systemName: "book.closed.fill").foregroundColor(.inkTextSecondary).font(.system(size: 36)))
                    }
                }

                Text(vm.seriesName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.inkTextPrimary)
                    .multilineTextAlignment(.center)

                Text(vm.destinationDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.inkBlue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.inkBlue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(width: 180)

            // Right column — all controls
            VStack(spacing: 12) {
                SmartFieldRow(label: "Title", value: vm.title, confirmed: !vm.userEditedTitle)
                SmartFieldRow(label: "Series", value: vm.seriesName, confirmed: true)
                SmartFieldRow(label: "Volume", value: vm.volumeNumber.isEmpty ? "—" : vm.volumeNumber, confirmed: false)

                // Direction toggle
                directionToggle
                    .padding(12)
                    .background(Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Device selector
                deviceSelector
                    .padding(12)
                    .background(Color.inkSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if vm.shouldShowPanelStrip {
                    PageFlagStrip(
                        flaggedIndices: vm.flaggedPageIndices,
                        totalPages: vm.pageCount
                    )
                }

                DisclosureGroup("Advanced options", isExpanded: $vm.showAdvanced) {
                    PipelineSelector(selectedPipeline: $vm.selectedPipeline, pdf: nil)
                        .padding(.top, 8)
                }
                .foregroundColor(.inkTextSecondary)

                // Action buttons
                HStack(spacing: 12) {
                    Button("Advanced Settings") { showingConvertSettings = true }
                        .font(.system(size: 14))
                        .foregroundColor(.inkTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.inkSurfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button(action: onConfirm) {
                        Text("Add to Library →")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.inkBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(32)
    }

    @ViewBuilder
    private var directionToggle: some View {
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
                                .onChange(of: vm.isManga) {
                    vm.userEditedDirection = true
                }
        }
    }

    @ViewBuilder
    private var deviceSelector: some View {
        HStack {
            let symbol = vm.destinationDevice?.deviceType.sfSymbol ?? "questionmark.circle"
            Image(systemName: symbol)
                .foregroundColor(.inkBlue)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sending to")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                let deviceName = vm.destinationDevice?.name ?? "No device — tap to add"
                Text(deviceName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.inkTextPrimary)
            }
            Spacer()
        }
    }
}

// MARK: - Skipped Import (3rd+ time, known series)
struct SkippedImportView: View {
    @ObservedObject var vm: SmartImportViewModel
    let onConfirm: () -> Void
    let onChange: () -> Void
    @State private var countdown: Int = 3
    @State private var timerActive = true
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
                let skipDeviceName = vm.destinationDevice?.name ?? "device"
                Text("\(vm.seriesName) · \(skipDeviceName)")
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

            CountdownRing(total: 3, remaining: countdown)

            Spacer()

            Button("Change settings") {
                timerActive = false  // prevent auto-confirm after view switches
                onChange()
            }
                .font(.system(size: 14))
                .foregroundColor(.inkTextSecondary)
                .padding(.bottom, 30)
        }
        .onReceive(timer) { _ in
            guard timerActive else { return }
            if countdown > 1 { countdown -= 1 }
            else { onConfirm() }
        }
    }
}

// MARK: - Countdown Ring (used by SkippedImportView)
struct CountdownRing: View {
    let total: Int
    let remaining: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.inkBorderSubtle, lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(total, 1)))
                .stroke(
                    Color.inkGreen,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1.0), value: remaining)
            Text("\(remaining)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)
        }
        .frame(width: 52, height: 52)
    }
}

// MARK: - Animated Analysing View
struct AnalysingView: View {
    var seriesName: String = ""
    @State private var rotation: Double = 0
    @State private var phase: String = "Reading metadata…"

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color.inkBorderSubtle, lineWidth: 5)
                    .frame(width: 64, height: 64)

                // Spinning arc
                Circle()
                    .trim(from: 0.08, to: 0.82)
                    .stroke(
                        LinearGradient(
                            colors: [Color.inkBlue, Color.purple.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(rotation))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: rotation
                    )
            }
            .onAppear { rotation = 360 }

            VStack(spacing: 6) {
                Text(seriesName.isEmpty ? "Analysing…" : seriesName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(phase)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                    .id(phase)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: phase)
            }
        }
        .task {
            // Cycle through human-readable phases to match backend stages
            let phases = ["Reading metadata…", "Scanning panels…", "Checking series memory…"]
            for p in phases {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { phase = p }
            }
        }
    }
}

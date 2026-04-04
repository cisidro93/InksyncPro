import SwiftUI
import PencilKit

struct PlannerEditorView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @Binding var project: PlannerProject
    @State private var selectedPageIndex: Int = 0
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    @State private var isShowingLinkOverlay = false
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var showingErrorAlert = false
    @State private var errorAlertTitle: String = "Export Failed"
    @State private var exportErrorMessage = ""
    @State private var showingAIAssistant = false
    @State private var isGeneratingAI = false
    @State private var aiPrompt = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Document Canvas Area
            GeometryReader { geo in
                ZStack {
                    // Page Background Layer
                    if project.pages.indices.contains(selectedPageIndex) {
                        let page = project.pages[selectedPageIndex]
                        
                        // Render Base Background if exists
                        if let bgData = page.backgroundImageData, let uiImage = UIImage(data: bgData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            ZStack {
                                Color.white
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .shadow(radius: 5)
                                
                                // AI Assistant Empty State Call-to-Action
                                if !showingAIAssistant {
                                    VStack(spacing: 16) {
                                        Image(systemName: "wand.and.stars")
                                            .font(.system(size: 48))
                                            .foregroundColor(.gray.opacity(0.5))
                                        Text("Blank Canvas Syndrome?")
                                            .font(.title3).bold()
                                            .foregroundColor(.gray)
                                        Button(action: { showingAIAssistant = true }) {
                                            Text("Generate AI Layout")
                                                .font(.headline)
                                                .padding(.horizontal, 24)
                                                .padding(.vertical, 12)
                                                .background(Color.accentColor.opacity(0.9))
                                                .foregroundColor(.white)
                                                .cornerRadius(12)
                                        }
                                    }
                                }
                                
                                // AI Generation Sheet Overlay
                                if showingAIAssistant {
                                    VStack(spacing: 20) {
                                        Text("AI Template Generator")
                                            .font(.headline)
                                        
                                        TextField("e.g. Weekly workout grid, Storyboard, Meeting Notes...", text: $aiPrompt)
                                            .textFieldStyle(.roundedBorder)
                                        
                                        HStack {
                                            Button("Cancel") { showingAIAssistant = false }
                                                .foregroundColor(.red)
                                            Spacer()
                                            Button(action: {
                                                generateAILayout(prompt: aiPrompt.isEmpty ? "Grid Notes" : aiPrompt)
                                            }) {
                                                if isGeneratingAI {
                                                    ProgressView()
                                                } else {
                                                    Text("Generate")
                                                        .bold()
                                                }
                                            }
                                            .disabled(isGeneratingAI)
                                        }
                                    }
                                    .padding(24)
                                    .frame(width: 350)
                                    .background(Color(.systemBackground))
                                    .cornerRadius(16)
                                    .shadow(radius: 20)
                                }
                            }
                        }
                        
                        // Vector Overlay Elements (Links, Shapes)
                        ForEach(page.elements) { element in
                            if element.type == .linkZone {
                                let rect = CoordinateConverter.denormalize(rect: element.rect, in: geo.size)
                                Rectangle()
                                    .stroke(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5]))
                                    .background(Color.blue.opacity(0.1))
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .overlay(
                                        Text("LINK")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                            .position(x: rect.midX, y: rect.midY)
                                    )
                            }
                        }
                        
                        // PencilKit Drawing Layer
                        PDFCanvasView(
                            canvasView: $canvasView,
                            drawingData: $project.pages[selectedPageIndex].drawingData
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            
            // Bottom Page Picker & Management Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(0..<project.pages.count, id: \.self) { index in
                        Button(action: {
                            changePage(to: index)
                        }) {
                            VStack {
                                Text("\(index + 1)")
                                    .font(.headline)
                                    .foregroundColor(selectedPageIndex == index ? .white : .primary)
                            }
                            .frame(width: 50, height: 60)
                            .background(selectedPageIndex == index ? Color.accentColor : Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        }
                    }
                    
                    Button(action: addBlankPage) {
                        Image(systemName: "plus")
                            .frame(width: 50, height: 60)
                            .background(Color(.systemFill))
                            .cornerRadius(8)
                    }
                }
                .padding()
            }
            .frame(height: 100)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: addLinkZone) {
                        Image(systemName: "link.badge.plus")
                    }
                    Button(action: exportPDF) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(isExporting)
                }
            }
        }
        .overlay(
            Group {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: 15) {
                            ProgressView("Generating PDF...", value: exportProgress, total: 1.0)
                                .accentColor(.accentColor)
                                .padding()
                        }
                        .frame(width: 250)
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 10)
                    }
                }
            }
        )
        .alert(errorAlertTitle, isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage)
        }
        .onAppear {
            toolPicker.setVisible(true, forFirstResponder: canvasView)
            toolPicker.addObserver(canvasView)
            canvasView.becomeFirstResponder()
        }
        .onDisappear {
            // Save state of current page before leaving
            if project.pages.indices.contains(selectedPageIndex) {
                project.pages[selectedPageIndex].drawingData = canvasView.drawing.dataRepresentation()
            }
        }
    }
    
    private func changePage(to newIndex: Int) {
        // Save old page drawing
        project.pages[selectedPageIndex].drawingData = canvasView.drawing.dataRepresentation()
        
        // Load new page
        selectedPageIndex = newIndex
        do {
            let data = project.pages[newIndex].drawingData
            canvasView.drawing = try PKDrawing(data: data)
        } catch {
            canvasView.drawing = PKDrawing()
        }
    }
    
    private func addBlankPage() {
        project.pages[selectedPageIndex].drawingData = canvasView.drawing.dataRepresentation()
        
        let newPage = PlannerPage()
        project.pages.append(newPage)
        changePage(to: project.pages.count - 1)
    }
    
    private func addLinkZone() {
        // Demo: Drops a 20% square in the middle of the screen
        let linkElement = PlannerElement(
            type: .linkZone,
            rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        )
        project.pages[selectedPageIndex].elements.append(linkElement)
    }
    
    private func exportPDF() {
        // Force save current strokes
        if project.pages.indices.contains(selectedPageIndex) {
            project.pages[selectedPageIndex].drawingData = canvasView.drawing.dataRepresentation()
        }
        
        isExporting = true
        exportProgress = 0.0
        
        let projectToExport = project
        let titleSafe = project.title
        
        // Background thread generation to prevent main-thread UI lock (Competitor review fix)
        Task.detached {
            do {
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let outputURL = docsDir.appendingPathComponent("\(titleSafe).pdf")
                
                try PlannerPDFGenerator.generate(from: projectToExport, to: outputURL) { progress in
                    Task { @MainActor in
                        self.exportProgress = progress
                    }
                }
                
                Task { @MainActor in
                    self.isExporting = false
                    Logger.shared.log("Successfully Exported to \(outputURL.path)", category: "Export", type: .success)
                    
                    // ✅ Add to Queue Manager so it displays in the Go Mode library UI alongside Pro Mode
                    let stem = outputURL.deletingPathExtension().lastPathComponent
                    if !ConversionQueueManager.shared.completedGoSourceStems.contains(stem) {
                        ConversionQueueManager.shared.completedGoSourceStems.append(stem)
                    }
                    
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRescan"), object: nil, userInfo: ["mode": "Pro"])
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.exportErrorMessage = error.localizedDescription
                    self.showingErrorAlert = true
                    Logger.shared.log("Export Failed: \(error.localizedDescription)", category: "Export", type: .error)
                }
            }
        }
    }
    
    private func generateAILayout(prompt: String) {
        let vendor = settingsManager.conversionSettings.aiVendor
        let apiKey: String
        switch vendor {
        case .openRouter: apiKey = settingsManager.conversionSettings.openRouterAPIKey
        case .openAI: apiKey = settingsManager.conversionSettings.openAIAPIKey
        case .anthropic: apiKey = settingsManager.conversionSettings.anthropicAPIKey
        case .gemini: apiKey = settingsManager.conversionSettings.geminiAPIKey
        }
        
        guard !apiKey.isEmpty else {
            self.errorAlertTitle = "Missing API Key"
            self.exportErrorMessage = "Please add your API key for \(vendor.rawValue) in Settings -> Integrations first."
            self.showingErrorAlert = true
            return
        }
        
        isGeneratingAI = true
        
        Task {
            do {
                // Use background thread so UI doesn't freeze during image rendering from JSON parsing
                let canvasImage = try await AILayoutGenerator.generateLayout(prompt: prompt, vendor: vendor, apiKey: apiKey)
                
                guard let data = canvasImage.pngData() else {
                    throw NSError(domain: "AILayoutGenerator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to read layout image data."])
                }
                
                await MainActor.run {
                    if project.pages.indices.contains(selectedPageIndex) {
                        project.pages[selectedPageIndex].backgroundImageData = data
                    }
                    self.isGeneratingAI = false
                    self.showingAIAssistant = false
                    self.aiPrompt = ""
                    Logger.shared.log("AI Layout Generated successfully", category: "AI Pro Mode", type: .success)
                }
            } catch {
                await MainActor.run {
                    self.isGeneratingAI = false
                    self.showingAIAssistant = false
                    self.errorAlertTitle = "AI Layout Failed"
                    self.exportErrorMessage = error.localizedDescription
                    self.showingErrorAlert = true
                }
            }
        }
    }
}

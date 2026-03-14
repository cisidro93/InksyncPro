import SwiftUI

struct PlannerGalleryView: View {
    @Environment(\.dismiss) var dismiss
    @State private var promptText: String = ""
    @State private var isGenerating = false
    @State private var selectedDevice: TargetDeviceProfile = .original
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""
    
    // Hardcoded Templates for Demo
    let predefinedTemplates = [
        ("2026 Yearly Planner", "Full year hyperlinked calendar", "calendar"),
        ("90-Day Tracker", "Fitness and habit tracking grids", "figure.run"),
        ("Developer Journal", "Standup notes and meeting logs", "chevron.left.forwardslash.chevron.right")
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    
                    // Hardware Optimization
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target Hardware")
                            .font(.headline)
                        Text("Templates will be generated to match the exact resolution of the selected device to prevent scaling blur.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Picker("Device", selection: $selectedDevice) {
                            Text("Amazon Kindle Scribe").tag(TargetDeviceProfile.scribe)
                            Text("Amazon Paperwhite").tag(TargetDeviceProfile.paperwhite11)
                            Text("Onyx Boox Note Air 3").tag(TargetDeviceProfile.booxNoteAir3C)
                            Text("Kobo Elipsa 2E").tag(TargetDeviceProfile.koboElipsa2E)
                            Text("Apple iPad Pro 11\"").tag(TargetDeviceProfile.original)
                        }
                        .pickerStyle(MenuPickerStyle())
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)
                    
                    // AI Generator
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI Generator")
                            .font(.headline)
                        
                        TextEditor(text: $promptText)
                            .frame(height: 100)
                            .padding(4)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                        
                        Button(action: generateFromAI) {
                            HStack {
                                Spacer()
                                if isGenerating {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: "wand.and.stars")
                                    Text("Generate Planner")
                                }
                                Spacer()
                            }
                            .padding()
                            .background(promptText.isEmpty ? Color.gray : Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(promptText.isEmpty || isGenerating)
                    }
                    .padding(.horizontal)
                    
                    // Pre-Built Gallery
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Curated Templates")
                            .font(.headline)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 15) {
                            ForEach(predefinedTemplates, id: \.0) { template in
                                VStack(alignment: .leading) {
                                    Image(systemName: template.2)
                                        .font(.largeTitle)
                                        .foregroundColor(.accentColor)
                                        .padding(.bottom, 5)
                                    
                                    Text(template.0)
                                        .font(.subheadline)
                                        .bold()
                                    
                                    Text(template.1)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                                .onTapGesture {
                                    generatePrebuilt(name: template.0)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Template Gallery")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Generation Failed", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func generateFromAI() {
        Logger.shared.log("AI Generation Triggered with prompt: \(promptText)", category: "AIGenerator", type: .info)
        isGenerating = true
        let safeName = promptText.prefix(20).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let fileName = "AI_\(safeName).pdf"
        generateMockPlanner(title: String(promptText.prefix(20)), fileName: fileName)
    }
    
    private func generatePrebuilt(name: String) {
        Logger.shared.log("Prebuilt Template Selected: \(name)", category: "Gallery", type: .info)
        isGenerating = true
        let safeName = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let fileName = "\(safeName).pdf"
        generateMockPlanner(title: name, fileName: fileName)
    }
    
    private func generateMockPlanner(title: String, fileName: String) {
        Task.detached {
            do {
                var project = PlannerProject(title: title)
                project.targetDeviceProfile = await MainActor.run { self.selectedDevice }
                project.pages.append(PlannerPage()) // 1 blank page placeholder
                
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let outputURL = docsDir.appendingPathComponent(fileName)
                
                try PlannerPDFGenerator.generate(from: project, to: outputURL)
                
                await MainActor.run {
                    self.isGenerating = false
                    Logger.shared.log("Successfully Exported to \(outputURL.path)", category: "Export", type: .success)
                    
                    // ✅ Add to Queue Manager so it displays in the Go Mode library UI
                    let stem = outputURL.deletingPathExtension().lastPathComponent
                    if !ConversionQueueManager.shared.completedGoSourceStems.contains(stem) {
                        ConversionQueueManager.shared.completedGoSourceStems.append(stem)
                    }
                    
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRescan"), object: nil, userInfo: ["mode": "Go"])
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription
                    self.showingErrorAlert = true
                    Logger.shared.log("Export Failed: \(error.localizedDescription)", category: "Export", type: .error)
                }
            }
        }
    }
}

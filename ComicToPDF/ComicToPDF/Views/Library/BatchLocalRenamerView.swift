import SwiftUI
import ZIPFoundation

/// The Centralized Dashboard for high-speed local XML scraping and renaming. Replace the non-deterministic OpenAI framework.
struct BatchLocalRenamerView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdfs: [ConvertedPDF]
    
    @State private var processingStates: [UUID: ProcessingState] = [:]
    @State private var isProcessing = false
    @State private var processedCount = 0
    
    // UI Layout Check
    @State private var showConfirm = false
    
    enum ProcessingState: Equatable {
        case waiting
        case extracting
        case renaming
        case finished(String)
        case failed(String)
        case warning(String)
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if !isProcessing && processedCount == 0 {
                    instructionsView
                } else {
                    processingListView
                }
            }
            .navigationTitle("Physical Disk Renamer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isProcessing {
                        Button("Cancel") { dismiss() }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isProcessing && processedCount == 0 {
                        Button("Start Scan") {
                            showConfirm = true
                        }
                        .bold()
                        .foregroundColor(Theme.purple)
                    } else if !isProcessing && processedCount > 0 {
                        Button("Done") { dismiss() }
                            .bold()
                    }
                }
            }
            .alert("Atomic Rename Confirmation", isPresented: $showConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Confirm Destructive Rename", role: .destructive) {
                    startBatchProcess()
                }
            } message: {
                Text("This will instantly rip the ComicInfo.xml out of \(pdfs.count) archives and irrevocably restyle the native FileSystem layers. Proceed?")
            }
            .onAppear {
                for pdf in pdfs {
                    processingStates[pdf.id] = .waiting
                }
            }
        }
    }
    
    private var instructionsView: some View {
        VStack(spacing: 24) {
            Image(systemName: "cpu")
                .font(.system(size: 60))
                .foregroundColor(Theme.blue)
            
            Text("Physical File Renaming")
                .font(.title2.bold())
            
            VStack(alignment: .leading, spacing: 16) {
                InstructionRow(icon: "bolt.fill", title: "Zero API Latency", desc: "No AI required. Scans metadata locally in milliseconds.")
                InstructionRow(icon: "lock.shield", title: "Deterministic Atomicity", desc: "Automatically handles OS constraints and prevents file-name collisions.")
                InstructionRow(icon: "archivebox", title: "Streamed Zips", desc: "Instantly locates headers without expanding massive payload blocks into memory.")
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.top, 40)
    }
    
    private var processingListView: some View {
        List(pdfs) { pdf in
            let state = processingStates[pdf.id] ?? .waiting
            
            HStack(spacing: 16) {
                // Status Icon
                Group {
                    switch state {
                    case .waiting: Image(systemName: "clock").foregroundColor(.secondary)
                    case .extracting, .renaming: ProgressView().scaleEffect(0.8)
                    case .finished: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    }
                }
                .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(pdf.name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    switch state {
                    case .waiting: Text("Queued").font(.caption).foregroundColor(.secondary)
                    case .extracting: Text("Streaming Header...").font(.caption).foregroundColor(Theme.blue)
                    case .renaming: Text("Applying Mutator...").font(.caption).foregroundColor(Theme.purple)
                    case .finished(let newName): 
                        Text("Renamed to: \(newName)").font(.caption).foregroundColor(.green)
                    case .failed(let err): 
                        Text("Error: \(err)").font(.caption2).foregroundColor(.red).lineLimit(2)
                    case .warning(let msg):
                        Text("Warning: \(msg)").font(.caption2).foregroundColor(.orange).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func startBatchProcess() {
        isProcessing = true
        
        Task {
            // Fluid Concurrent Queue (Prevents main thread hanging)
            for pdf in pdfs {
                processingStates[pdf.id] = .extracting
                
                // Jump to Background Thread
                let resultResult: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        return .success(try LocalComicInfoService.shared.generateDeterministicFilename(from: pdf.url))
                    } catch {
                        return .failure(error)
                    }
                }.value
                
                switch resultResult {
                case .success(let newName):
                    processingStates[pdf.id] = .renaming
                    
                    do {
                        // Return to MainActor for ConversionManager operations (which edit core state)
                        try await conversionManager.safelyRenamePhysicalFile(pdf: pdf, newName: newName)
                        processingStates[pdf.id] = .finished(newName)
                    } catch {
                        processingStates[pdf.id] = .warning("Rename Collision/Fail: \(error.localizedDescription)")
                    }
                    
                case .failure(let error):
                    processingStates[pdf.id] = .failed(error.localizedDescription)
                }
                
                processedCount += 1
            }
            
            isProcessing = false
        }
    }
}

private struct InstructionRow: View {
    let icon: String
    let title: String
    let desc: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(Theme.purple)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(desc).font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import CoreImage

struct GoConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @StateObject private var queueManager = ConversionQueueManager.shared
    
    @State private var selectedFiles: [URL] = []
    @State private var isTargetingManga = true
    @State private var useLiquidEInk = true
    @State private var showingFilePicker = false
    @State private var showingShareSheet = false
    @State private var convertedEpubURLs: [URL] = []
    @State private var conversionTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Go Convert")
                .font(.largeTitle)
                .bold()
                .padding(.top, 40)
            
            // Drag and Drop Zone / File Picker Button
            Button {
                showingFilePicker = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .background(Color.blue.opacity(0.05).cornerRadius(24))
                    
                    VStack(spacing: 12) {
                        Image(systemName: "plus.square.dashed")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                        
                        if selectedFiles.isEmpty {
                            Text("Tap to Select Files")
                                .font(.title3)
                                .bold()
                                .foregroundStyle(.primary)
                            Text("or Drag & Drop CBZ/PDF here")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(selectedFiles.count) File(s) Selected")
                                .font(.title3)
                                .bold()
                                .foregroundStyle(.blue)
                            Text("Ready for processing")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 300)
            .padding(.horizontal, 32)
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(onDocumentsPicked: { urls in
                    self.selectedFiles = urls
                })
            }
            
            VStack(spacing: 16) {
                // Content Type Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Content Type").font(.headline)
                    Picker("Content Type", selection: $isTargetingManga) {
                        Text("Manga (Right-to-Left)").tag(true)
                        Text("Western Comic (L-to-R)").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 32)
                
                // Device Target Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target Device").font(.headline)
                    Picker("Target Device", selection: $conversionManager.conversionSettings.targetDevice) {
                        ForEach(KindleDeviceType.allCases, id: \.self) { device in
                            Text(device.rawValue).tag(device)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                
                // Liquid E-Ink Optimization
                Toggle(isOn: $useLiquidEInk) {
                    VStack(alignment: .leading) {
                        Text("✨ Liquid E-Ink Optimization")
                            .font(.headline)
                        Text("Applies auto-levels, unsharp masking, and gamma correction for perfect contrast.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 32)
            }
            
            Spacer()
            
            Spacer()
            
            // Queue Status Hub OR Convert Action
            Group {
            if queueManager.isProcessing || queueManager.activeItem != nil {
                VStack(spacing: 8) {
                    // Active Item HUD
                    if let active = queueManager.activeItem {
                        VStack(spacing: 6) {
                            Text(queueManager.statusMessage)
                                .font(.subheadline)
                                .bold()
                                .lineLimit(1)
                            
                            ProgressView(value: queueManager.currentProgress)
                                .tint(.blue)
                            
                            // ✅ NEW: Queue Timer Display
                            HStack {
                                Text("\(formatTime(queueManager.elapsedTime)) elapsed")
                                Spacer()
                                if let etr = queueManager.estimatedTimeRemaining {
                                    Text("ETR: \(formatTime(etr))")
                                } else {
                                    Text("Estimating...")
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    
                    // Queue List count
                    if !queueManager.queue.isEmpty {
                        Text("Up Next: \(queueManager.queue.count) items...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Cancel Queue
                    Button(role: .destructive) {
                        queueManager.cancelAll()
                    } label: {
                        Text("Cancel Queue")
                            .bold()
                            .frame(maxWidth: 200)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.15))
                            .foregroundColor(.red)
                            .cornerRadius(10)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)
            } else {
                Button {
                    startGoConversion()
                } label: {
                    Text("Add to Conversion Queue")
                        .font(.title2)
                        .bold()
                        .frame(maxWidth: 400)
                        .padding()
                        .background(selectedFiles.isEmpty ? Color.blue.opacity(0.5) : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                }
                .disabled(selectedFiles.isEmpty)
            }
            } // Close Group
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: convertedEpubURLs)
        }
    }
    
    private func startGoConversion() {
        guard !selectedFiles.isEmpty else { return }
        
        var settingsForGo = conversionManager.conversionSettings
        settingsForGo.mangaMode = isTargetingManga
        settingsForGo.optimizeForDevice = true
        settingsForGo.compressionQuality = .high
        settingsForGo.outputFormat = .epub
        settingsForGo.outputPipeline = .standard // Fast, stable standard EPUB default for Go mode
        settingsForGo.splitMode = .web // 🔥 CRITICAL: Go Mode always auto-splits massive omnibuses for Send-To-Kindle compatibility
        
        if useLiquidEInk {
            settingsForGo.imageEnhancement.autoContrast = true
            settingsForGo.imageEnhancement.sharpness = 0.5
            settingsForGo.imageEnhancement.gamma = 0.8
        } else {
            settingsForGo.imageEnhancement.autoContrast = false
            settingsForGo.imageEnhancement.sharpness = 0.0
            settingsForGo.imageEnhancement.gamma = 1.0
            settingsForGo.imageEnhancement.grayscale = false
            settingsForGo.imageEnhancement.invertColors = false
        }
        
        for file in selectedFiles {
            queueManager.enqueue(url: file, settings: settingsForGo, mode: .go)
        }
        
        // Immediately clear the selection area so they can drop more files
        selectedFiles.removeAll()
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "00:00"
    }
}

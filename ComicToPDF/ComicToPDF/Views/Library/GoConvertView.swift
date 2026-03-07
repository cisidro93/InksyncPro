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
    @State private var shareItems: [URL] = []
    @State private var showingShareSheet = false
    
    // Only Go-mode converted files, newest first
    private var goConvertedFiles: [ConvertedPDF] {
        conversionManager.convertedPDFs
            .filter { $0.addedByMode == .go }
            .reversed()
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Go Convert")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top, 40)
                
                // MARK: - Drop Zone
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
                .frame(maxWidth: .infinity, minHeight: 200)
                .padding(.horizontal, 32)
                .sheet(isPresented: $showingFilePicker) {
                    DocumentPicker(onDocumentsPicked: { urls in
                        self.selectedFiles = urls
                    })
                }
                
                // MARK: - Content Type + Device Pickers
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content Type").font(.headline)
                        Picker("Content Type", selection: $isTargetingManga) {
                            Text("Manga (Right-to-Left)").tag(true)
                            Text("Western Comic (L-to-R)").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 32)
                    
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
                
                // MARK: - Queue Hub / Convert Button
                Group {
                    if queueManager.isProcessing || queueManager.activeItem != nil {
                        VStack(spacing: 8) {
                            if let _ = queueManager.activeItem {
                                VStack(spacing: 6) {
                                    Text(queueManager.statusMessage)
                                        .font(.subheadline)
                                        .bold()
                                        .lineLimit(1)
                                    
                                    ProgressView(value: queueManager.currentProgress)
                                        .tint(.blue)
                                    
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
                            
                            if !queueManager.queue.isEmpty {
                                Text("Up Next: \(queueManager.queue.count) items...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
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
                }
                
                // MARK: - ✅ Recently Converted (Go Mode Output)
                if !goConvertedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Recently Converted", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundColor(.green)
                            Spacer()
                            Text("\(goConvertedFiles.count) file\(goConvertedFiles.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 32)
                        
                        ForEach(goConvertedFiles) { pdf in
                            HStack(spacing: 12) {
                                // File Icon
                                Image(systemName: "doc.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                    .frame(width: 40)
                                
                                // File Info
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pdf.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text(pdf.formattedSize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                // Quick Share Button
                                Button {
                                    shareItems = [pdf.url]
                                    showingShareSheet = true
                                } label: {
                                    Label("Send", systemImage: "paperplane.fill")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(20)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal, 32)
                        }
                        
                        // Batch Share All Button
                        if goConvertedFiles.count > 1 {
                            Button {
                                shareItems = goConvertedFiles.map { $0.url }
                                showingShareSheet = true
                            } label: {
                                Label("Share All \(goConvertedFiles.count) Files", systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal, 32)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Spacer(minLength: 40)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: shareItems)
        }
    }
    
    private func startGoConversion() {
        guard !selectedFiles.isEmpty else { return }
        
        var settingsForGo = conversionManager.conversionSettings
        settingsForGo.mangaMode = isTargetingManga
        settingsForGo.optimizeForDevice = true
        settingsForGo.compressionQuality = .high
        settingsForGo.outputFormat = .epub
        settingsForGo.outputPipeline = .standard
        settingsForGo.splitMode = .web // 🔥 Always web-split for Send-To-Kindle compatibility
        
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
        
        selectedFiles.removeAll()
    }
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "00:00"
    }
}

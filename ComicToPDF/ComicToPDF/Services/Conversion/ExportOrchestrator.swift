import Foundation
import SwiftUI
import CoreGraphics

@MainActor
class ExportOrchestrator {
    static let shared = ExportOrchestrator()

    func exportForCloudSync(_ pdf: ConvertedPDF, manager: ConversionManager) async -> URL? {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        if pdf.contentType == .book {
            let exportURL = tempDir.appendingPathComponent(pdf.name)
            try? fileManager.removeItem(at: exportURL)
            do {
                try fileManager.copyItem(at: pdf.url, to: exportURL)
                Logger.shared.log("Book Export: Safe pass-through for \(pdf.name)", category: "Export")
                return exportURL
            } catch {
                Logger.shared.log("❌ Book Export Failed: \(error.localizedDescription)", category: "Export", type: .error)
                return nil
            }
        }
        
        if manager.conversionSettings.outputFormat == .pdf {
            let exportName = pdf.name.replacingOccurrences(of: ".cbz", with: ".pdf")
            let exportURL = tempDir.appendingPathComponent(exportName)
            
            TaskEngine.shared.isConverting = true; TaskEngine.shared.processingStatus = "Generating PDF..."
            defer { 
                TaskEngine.shared.isConverting = false 
                Task { @MainActor in TaskEngine.shared.processingStatus = "" }
            }
            
            do {
                let imageURLs = try await EditorSessionManager.shared.extractImageURLs(from: pdf.url)
                try PDFGenerator.generate(from: imageURLs, to: exportURL, mangaMode: manager.conversionSettings.mangaMode, chapters: pdf.chapters, settings: manager.conversionSettings) { progress in
                    Task { @MainActor in TaskEngine.shared.processingStatus = "Processing \(Int(progress * 100))%" }
                }
                return exportURL
            } catch {
                Logger.shared.log("❌ PDF Export Failed: \(error)", category: "Export")
                return nil
            }
        }
        
        let exportName = pdf.url.lastPathComponent
        let exportURL = tempDir.appendingPathComponent(exportName)
        try? fileManager.removeItem(at: exportURL)
        
        TaskEngine.shared.isConverting = true; TaskEngine.shared.processingStatus = "Preparing Export..."; TaskEngine.shared.statusMessage = "Embedding Metadata..."
        defer { 
            TaskEngine.shared.isConverting = false 
            TaskEngine.shared.statusMessage = nil 
            Task { @MainActor in TaskEngine.shared.processingStatus = "" }
        }
        
        do {
            Logger.shared.log("Starting Cloud Export for \(pdf.name)", category: "Export")
            try fileManager.copyItem(at: pdf.url, to: exportURL)
            
            var panelsToInject = [Int: [PanelExtractor.Panel]]()
            if manager.conversionSettings.isGuidedView {
                panelsToInject = await manager.getCombinedManifest(for: pdf)
                let files = try await EditorSessionManager.shared.extractImageURLs(from: pdf.url)
                
                for (index, fileURL) in files.enumerated() {
                    if panelsToInject[index] == nil && manager.conversionSettings.enablePanelSplit {
                         if let image = UIImage(contentsOfFile: fileURL.path) {
                            let detected = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: manager.conversionSettings.mangaMode)
                            if !detected.isEmpty {
                                let editedRects = await withCheckedContinuation { (continuation: CheckedContinuation<[CGRect], Never>) in
                                    Task { @MainActor in
                                        manager.currentEditorImage = image
                                        manager.currentEditorPanels = detected.map { $0.boundingBox }
                                        manager.setPanelEditorContinuation(continuation) // Requires helper on manager
                                        manager.isPresentingPanelEditor = true
                                    }
                                }
                                panelsToInject[index] = editedRects.map { PanelExtractor.Panel(boundingBox: $0) }
                            }
                        }
                    }
                    let progress = Double(index) / Double(files.count)
                    Task { @MainActor in TaskEngine.shared.conversionProgress = progress }
                }
            }
            
            try? await manager.injectMetadata(into: exportURL, panels: panelsToInject, metadata: pdf.metadata)
            return exportURL
        } catch {
            Logger.shared.log("❌ Cloud Export Failed: \(error)", category: "Export")
            return nil
        }
    }
    
    // MARK: - KFX Export
    func exportForKFX(_ pdf: ConvertedPDF, manager: ConversionManager) async -> URL? {
        TaskEngine.shared.isConverting = true
        TaskEngine.shared.processingStatus = "Building KFX Package..."
        TaskEngine.shared.statusMessage = "Extracting images and scripts..."
        
        defer {
            TaskEngine.shared.isConverting = false
            TaskEngine.shared.statusMessage = nil
            Task { @MainActor in TaskEngine.shared.processingStatus = "" }
        }
        
        do {
            let converter = CBZToEPUBConverter()
            let outputURL = try await converter.buildKFXPackage(
                sourceURL: pdf.url,
                settings: manager.conversionSettings,
                metadata: pdf.metadata,
                progress: { progress in
                    Task { @MainActor in TaskEngine.shared.conversionProgress = progress }
                }
            )
            return outputURL
        } catch {
            Logger.shared.log("❌ KFX Export Failed: \(error.localizedDescription)", category: "Export", type: .error)
            return nil
        }
    }
    
    // MARK: - Local Sideload Export
    func exportForLocalSideload(_ pdf: ConvertedPDF, manager: ConversionManager) async -> URL? {
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDir = docDir.appendingPathComponent("KindleExports")
        
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true, attributes: nil)
        
        let tempName = "Kindle_HQ_\(pdf.name)"
        let targetURL = exportDir.appendingPathComponent(tempName)
        try? fileManager.removeItem(at: targetURL)
        
        if pdf.contentType == .book {
            do {
                try fileManager.copyItem(at: pdf.url, to: targetURL)
                Logger.shared.log("Book Export: Safe pass-through HQ for \(pdf.name)", category: "Export")
                return targetURL
            } catch {
                return nil
            }
        }
        
        if manager.conversionSettings.outputFormat == .pdf {
            TaskEngine.shared.isConverting = true; TaskEngine.shared.processingStatus = "Generating PDF..."
            defer { TaskEngine.shared.isConverting = false; Task { @MainActor in TaskEngine.shared.processingStatus = "" } }
            
            do {
                let pdName = pdf.name.replacingOccurrences(of: ".cbz", with: ".pdf")
                let pdfURL = exportDir.appendingPathComponent(pdName)
                try? fileManager.removeItem(at: pdfURL)
                
                let imageURLs = try await EditorSessionManager.shared.extractImageURLs(from: pdf.url)
                try PDFGenerator.generate(from: imageURLs, to: pdfURL, mangaMode: manager.conversionSettings.mangaMode, chapters: pdf.chapters, settings: manager.conversionSettings) { progress in
                    Task { @MainActor in TaskEngine.shared.processingStatus = "Processing \(Int(progress * 100))%" }
                }
                return pdfURL
            } catch {
                return nil
            }
        }
        
        do {
            manager.saveLibrary()
            let finalEPUB = try await ConversionEngine.shared.process(url: pdf.url, settings: manager.conversionSettings)
            let finalName = finalEPUB.lastPathComponent
            let destURL = exportDir.appendingPathComponent(finalName)
            if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
            try fileManager.moveItem(at: finalEPUB, to: destURL)
            return destURL
        } catch {
            return nil
        }
    }
}

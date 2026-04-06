import SwiftUI
import ZIPFoundation

extension ConversionManager {
    // MARK: - Sidecar Models
    struct SmartPanel: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    // MARK: - Pre-Flight Validation & Export
    
    enum ValidationResult {
        case success
        case warning(String)
        case failure(String)
    }
    
    func validateForExport(_ pdf: ConvertedPDF) -> ValidationResult {
        Logger.shared.log("Running Pre-Flight Check for: \(pdf.name)", category: "Validation")
        
        if AppSettingsManager.shared.conversionSettings.isGuidedView {
            let panels = PageModelStore.shared.getAllLegacyVisionPanels(for: pdf.id)
            if panels.isEmpty {
                return .warning("Guided View is enabled, but no panels were detected. The EPUB will export with default full-page views.")
            }
            
            for (pageIndex, pagePanels) in panels {
                if pagePanels.count > 20 {
                    return .warning("Page \(pageIndex + 1) has \(pagePanels.count) panels. This may cause performance issues on older Kindle devices.")
                }
                
                for (pIndex, panel) in pagePanels.enumerated() {
                    let r = panel.boundingBox
                    if r.minX < -0.01 || r.maxX > 1.01 || r.minY < -0.01 || r.maxY > 1.01 {
                        return .failure("Page \(pageIndex + 1), Panel \(pIndex + 1) has invalid coordinates. Please re-scan this page.")
                    }
                    if r.width < 0.05 || r.height < 0.05 {
                         return .warning("Page \(pageIndex + 1), Panel \(pIndex + 1) is extremely small (<5%). Check for artifacts.")
                    }
                }
            }
        }
        return .success
    }
    
    // MARK: - Comic Vault Export
    func exportForCloudSync(_ pdf: ConvertedPDF) async -> URL? {
        return await ExportOrchestrator.shared.exportForCloudSync(pdf, manager: self)
    }
    
    func exportForKFX(_ pdf: ConvertedPDF) async -> URL? {
        return await ExportOrchestrator.shared.exportForKFX(pdf, manager: self)
    }
    
    func exportForLocalSideload(_ pdf: ConvertedPDF) async -> URL? {
        return await ExportOrchestrator.shared.exportForLocalSideload(pdf, manager: self)
    }
    
    // MARK: - Metadata Injection
    func embedPanels(for pdf: ConvertedPDF) async {
        await MetadataInjector.shared.embedPanels(for: pdf, manager: self)
    }
    
    func injectMetadata(into archiveURL: URL, panels: [Int: [PanelExtractor.Panel]], metadata: PDFMetadata) async throws {
        try await MetadataInjector.shared.injectMetadata(into: archiveURL, panels: panels, metadata: metadata, manager: self)
    }
}

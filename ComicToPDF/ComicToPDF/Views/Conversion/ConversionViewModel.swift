import SwiftUI

class ConversionViewModel: ObservableObject {
    @Published var selectedPipeline: OutputPipeline = .standard
    @Published var isMangaMode: Bool = false
    @Published var showingPreview: Bool = false
    @Published var showingCalibreGuide: Bool = false
    
    // UI Helpers
    func pipelineIcon(for pipeline: OutputPipeline) -> String {
        switch pipeline {
        case .standard: return "doc.richtext"
        case .proPanel: return "rectangle.split.3x1"
        }
    }

    func cardAccentColor(for pipeline: OutputPipeline) -> Color {
        switch pipeline {
        case .standard: return .blue
        case .proPanel: return .purple
        }
    }

    func pipelineSubtitle(for pipeline: OutputPipeline) -> String {
        switch pipeline {
        case .standard:
            return "EPUB · No panel zoom · Cloud-safe (OneDrive, Google Drive, Send-to-Kindle)"
        case .proPanel:
            return "EPUB · Full Amazon Panel View Support · Universal Compatibility"
        }
    }

    func pipelineIsDisabled(_ pipeline: OutputPipeline, for pdf: ConvertedPDF, format: OutputFormat) -> Bool {
        if pipeline == .proPanel {
            if pdf.contentType == .book { return true }
            if format != .epub { return true }
        }
        return false
    }

    func applyPipeline(_ pipeline: OutputPipeline, to settings: inout ConversionSettings) {
        settings.outputPipeline = pipeline
        switch pipeline {
        case .standard:
            settings.enablePanelSplit = false
        case .proPanel:
            settings.enablePanelSplit = true
            settings.epubSettings.includeFullPage = true
        }
    }
}

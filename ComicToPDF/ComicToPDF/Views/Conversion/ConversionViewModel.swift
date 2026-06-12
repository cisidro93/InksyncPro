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

    func pipelineSubtitle(for pipeline: OutputPipeline, format: OutputFormat = .epub) -> String {
        switch pipeline {
        case .standard:
            if format == .epub {
                return "EPUB · No panel zoom · Cloud-safe (OneDrive, Google Drive, Send-to-Kindle)"
            } else if format == .pdf {
                return "PDF · High fidelity · Standard page layout"
            } else if format == .cbz {
                return "CBZ · High-fidelity archive · Standard page layout"
            } else {
                return "Standard page layout and format-native structure"
            }
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

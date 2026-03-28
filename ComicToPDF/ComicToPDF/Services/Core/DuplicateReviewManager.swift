import Foundation
import Combine
import SwiftUI

/// Service to scan the active library and detect exact byte/name structural clones
class DuplicateReviewManager: ObservableObject {
    @Published var duplicateGroups: [[ConvertedPDF]] = []
    
    /// Analyzes the active memory array for identical footprints
    @MainActor
    func assessDuplicates(in manager: ConversionManager) {
        let pdfs = manager.convertedPDFs
        
        var signatureMap = [String: [ConvertedPDF]]()
        for pdf in pdfs {
            // Generating a rigid identity signature (Name + ByteSize)
            let signature = "\(pdf.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))_bytes_\(pdf.fileSize)"
            signatureMap[signature, default: []].append(pdf)
        }
        
        self.duplicateGroups = signatureMap.values
            .filter { $0.count > 1 }
            .sorted { $0[0].name < $1[0].name }
    }
    
    /// Executes a purge on specific duplicate copies
    @MainActor
    func deleteItems(_ items: [ConvertedPDF], from manager: ConversionManager) {
        for pdf in items {
            manager.deletePDF(pdf)
        }
        
        // Re-assess
        assessDuplicates(in: manager)
    }
    
    @MainActor
    func keepTargetDiscardOthers(target: ConvertedPDF, group: [ConvertedPDF], manager: ConversionManager) {
        let toDelete = group.filter { $0.id != target.id }
        deleteItems(toDelete, from: manager)
    }
}

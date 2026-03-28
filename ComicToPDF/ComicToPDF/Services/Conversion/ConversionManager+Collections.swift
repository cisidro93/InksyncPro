import SwiftUI

extension ConversionManager {
    // MARK: - Collection Management
    
    func createCollection(name: String, icon: String, color: String) {
        collections.append(PDFCollection(id: UUID(), name: name, icon: icon, color: color, creationDate: Date()))
        saveLibrary()
    }
    
    func deleteCollection(_ collection: PDFCollection) {
        collections.removeAll { $0.id == collection.id }
        for i in 0..<convertedPDFs.count { 
            if convertedPDFs[i].collectionId == collection.id { 
                convertedPDFs[i].collectionId = nil 
            } 
        }
        saveLibrary()
    }
    
    func movePDFToCollection(_ pdf: ConvertedPDF, collectionId: UUID?) {
        if let idx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }) { 
            convertedPDFs[idx].collectionId = collectionId; 
            saveLibrary() 
        }
    }
    
    func updateCollectionOrder(collectionID: UUID, newOrderIDs: [UUID]) {
        if let idx = collections.firstIndex(where: { $0.id == collectionID }) {
            collections[idx].manualSortOrder = newOrderIDs
            saveLibrary()
        }
    }
    
    func setExplicitSeriesCover(for pdf: ConvertedPDF) {
        guard let collectionID = pdf.collectionId,
              let pdfIdx = convertedPDFs.firstIndex(where: { $0.id == pdf.id }),
              let colIdx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        
        // Remove from all others
        for i in 0..<convertedPDFs.count {
            if convertedPDFs[i].collectionId == collectionID {
                convertedPDFs[i].isExplicitSeriesCover = false
            }
        }
        
        convertedPDFs[pdfIdx].isExplicitSeriesCover = true
        collections[colIdx].explicitCoverFileID = pdf.id // ✅ Typo was explicitCoverPDFId in original error
        
        self.saveLibrary()
        self.objectWillChange.send()
    }
}

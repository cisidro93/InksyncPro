import Foundation
import UIKit
import SwiftUI

// Represents an editable panel region
struct EditablePanel: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect  // In image coordinates
    var order: Int    // Reading order
    var isSelected: Bool = false
    
    init(id: UUID = UUID(), rect: CGRect, order: Int) {
        self.id = id
        self.rect = rect
        self.order = order
    }
    
    // Create from detected panel
    init(from panel: PanelExtractor.Panel, order: Int) {
        self.id = UUID()
        self.rect = panel.boundingBox
        self.order = order
    }
    
    // Convert to normalized region for EPUB
    func toNormalizedRegion(imageSize: CGSize) -> PanelRegion {
        return PanelRegion(
            x: Double(rect.origin.x) / Double(imageSize.width),
            y: Double(rect.origin.y) / Double(imageSize.height),
            width: Double(rect.width) / Double(imageSize.width),
            height: Double(rect.height) / Double(imageSize.height),
            pageIndex: 0  // Set by caller
        )
    }
}

// Holds all pages and their panels for editing
// Holds all pages and their panels for editing
struct PanelEditSession: Identifiable {
    let id: UUID = UUID()
    var pages: [PageEditData]
    var currentPageIndex: Int = 0
    var readingDirection: EPUBSettings.ReadingDirection = .leftToRight
    // Track the temp directory so we can clean it up later
    var sessionTempDirectory: URL? 
    
    struct PageEditData: Identifiable {
        let id: UUID = UUID()
        let pageNumber: Int
        let imageURL: URL // MEMORY FIX: Store URL, not UIImage
        var panels: [EditablePanel]
    }
    
    var currentPage: PageEditData? {
        guard currentPageIndex < pages.count else { return nil }
        return pages[currentPageIndex]
    }
    
    mutating func updateCurrentPage(_ page: PageEditData) {
        guard currentPageIndex < pages.count else { return }
        pages[currentPageIndex] = page
    }
}

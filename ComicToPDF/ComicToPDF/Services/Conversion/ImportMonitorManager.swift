import Foundation
import SwiftUI
import Combine

/// Tracks the progress and results of background `ConversionManager.importFilesAsSeries` jobs.
/// This prevents the UI from locking up during massive Multi-Folder imports.
class ImportMonitorManager: ObservableObject {
    static let shared = ImportMonitorManager()
    
    @Published private(set) var isImporting: Bool = false
    @Published private(set) var totalFilesToProcess: Int = 0
    @Published private(set) var filesProcessed: Int = 0
    @Published private(set) var filesFailed: Int = 0
    
    // Alert state to show the user upon completion
    @Published var showCompletionReport: Bool = false
    @Published private(set) var finalReportMessage: String = ""
    
    private init() {}
    
    @MainActor
    func startImport(totalCount: Int) {
        self.isImporting = true
        self.totalFilesToProcess = totalCount
        self.filesProcessed = 0
        self.filesFailed = 0
        self.showCompletionReport = false
    }
    
    @MainActor
    func incrementSuccess() {
        self.filesProcessed += 1
    }
    
    @MainActor
    func incrementFailure() {
        self.filesProcessed += 1
        self.filesFailed += 1
    }
    
    @MainActor
    func completeImport() {
        self.isImporting = false
        
        let successful = totalFilesToProcess - filesFailed
        
        if filesFailed > 0 {
            self.finalReportMessage = "Successfully imported \(successful) files.\nFailed to import \(filesFailed) files."
        } else {
            self.finalReportMessage = "Successfully imported \(successful) files."
        }
        
        self.showCompletionReport = true
    }
    
    var progress: Double {
        guard totalFilesToProcess > 0 else { return 0 }
        return Double(filesProcessed) / Double(totalFilesToProcess)
    }
}

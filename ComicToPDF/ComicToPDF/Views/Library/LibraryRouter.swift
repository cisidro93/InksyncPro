import SwiftUI

enum LibrarySheetDestination: Identifiable {
    case smartListImporter
    case wifi
    case merge
    case cloudBrowser          // NEW: premium direct-API cloud browser
    case cloudSync(ConvertedPDF)
    case export(ConvertedPDF)
    case importQueue
    case directShare(ConvertedPDF)
    case details(ConvertedPDF)
    case searchMetadata(ConvertedPDF)
    case reviewMetadata
    case editMetadata(ConvertedPDF)
    case batchMetadata([ConvertedPDF])
    case cognitiveBatchRenamer([ConvertedPDF])
    case seriesAssignment(ConvertedPDF?, isBatch: Bool, selection: [ConvertedPDF])
    case stats
    case convert(ConvertedPDF)
    case ledger
    case metadataInbox
    case metadataSpreadsheet([ConvertedPDF])
    
    var id: String {
        switch self {
        case .smartListImporter: return "smartList"
        case .wifi: return "wifi"
        case .merge: return "merge"
        case .cloudBrowser: return "cloudBrowser"
        case .cloudSync(let p): return "cloudSync_\(p.id)"
        case .export(let p): return "export_\(p.id)"
        case .importQueue: return "importQueue"
        case .directShare(let p): return "directShare_\(p.id)"
        case .details(let p): return "details_\(p.id)"
        case .searchMetadata(let p): return "searchMeta_\(p.id)"
        case .reviewMetadata: return "reviewMetadata"
        case .editMetadata(let p): return "editMeta_\(p.id)"
        case .batchMetadata: return "batchMeta"
        case .cognitiveBatchRenamer: return "batchRenamer"
        case .seriesAssignment(let p, let batch, _): return "series_\(p?.id.uuidString ?? "batch_\(batch)")"
        case .stats: return "stats"
        case .convert(let p): return "convert_\(p.id)"
        case .ledger: return "ledger"
        case .metadataInbox: return "metadataInbox"
        case .metadataSpreadsheet: return "metadataSpreadsheet"
        }
    }
}

enum LibraryFullScreenDestination: Identifiable {
    case read(ConvertedPDF, initialReadingMode: String?)
    case advancedWorkspace(ConvertedPDF)
    case smartCollection(SmartCollectionRule)
    
    static func read(_ pdf: ConvertedPDF) -> LibraryFullScreenDestination {
        return .read(pdf, initialReadingMode: nil)
    }
    
    var id: String {
        switch self {
        case .read(let p, _): return "read_\(p.id)"
        case .advancedWorkspace(let p): return "workspace_\(p.id)"
        case .smartCollection(let rule): return "smartCollection_\(rule.id)"
        }
    }
}

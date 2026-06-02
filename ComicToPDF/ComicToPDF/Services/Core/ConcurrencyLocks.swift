import Foundation

public enum ConcurrencyLocks {
    /// A global lock to serialize all PDFKit document loading, page retrieval, and page rendering/drawing.
    public static let pdfLock = NSLock()
    
    /// A global lock to serialize all libunrar/Unrar archive operations.
    public static let unrarLock = NSLock()
}

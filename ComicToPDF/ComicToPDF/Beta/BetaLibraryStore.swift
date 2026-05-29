import Foundation
import SwiftData
import SwiftUI
import PDFKit
import ZIPFoundation
import Unrar

@MainActor
public final class BetaLibraryStore: ObservableObject {
    @Published public var books: [BetaBook] = []
    @Published public var isImporting = false
    @Published public var importProgress: Double = 0
    
    public let modelContext: ModelContext
    
    private let fileManager = FileManager.default
    private let librarySubdir = "Library"
    private let coverSubdir = "Covers"
    
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        createDirectoriesIfNeeded()
        fetchBooks()
    }
    
    /// Re-fetches the database records into the published array
    public func fetchBooks() {
        let descriptor = FetchDescriptor<BetaBook>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)])
        do {
            self.books = try modelContext.fetch(descriptor)
        } catch {
            print("BetaLibraryStore: Failed to fetch books: \(error)")
        }
    }
    
    /// Sets up subdirectories in Documents and Caches
    private func createDirectoriesIfNeeded() {
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let libraryDir = documentsDir.appendingPathComponent(librarySubdir)
        try? fileManager.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let coverDir = cachesDir.appendingPathComponent(coverSubdir)
        try? fileManager.createDirectory(at: coverDir, withIntermediateDirectories: true)
    }
    
    /// Returns the cached cover image file URL for a given book
    public func coverURL(for book: BetaBook) -> URL? {
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let fileURL = cachesDir.appendingPathComponent(coverSubdir).appendingPathComponent("\(book.id).jpg")
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
    
    /// Imports files asynchronously
    public func importFiles(from urls: [URL]) async {
        isImporting = true
        importProgress = 0
        
        let total = Double(urls.count)
        for (index, url) in urls.enumerated() {
            do {
                try await importSingleFile(at: url)
            } catch {
                print("BetaLibraryStore: Import failed for \(url.lastPathComponent): \(error)")
            }
            importProgress = Double(index + 1) / total
        }
        
        fetchBooks()
        isImporting = false
    }
    
    private func importSingleFile(at url: URL) async throws {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        
        let fileExtension = url.pathExtension.lowercased()
        guard ["cbz", "cbr", "pdf", "epub", "zip", "rar"].contains(fileExtension) else {
            throw NSError(domain: "BetaLibraryStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported format: \(fileExtension)"])
        }
        
        // 1. Determine Content Type
        var contentType: BetaContentType = .comic
        if fileExtension == "pdf" {
            contentType = .pdf
        } else if fileExtension == "epub" {
            contentType = .epub
        } else {
            // Auto-detect Manga vs Comic based on file name
            let filenameLower = url.lastPathComponent.lowercased()
            if filenameLower.contains("manga") || filenameLower.contains("vol") || filenameLower.contains("volume") || filenameLower.contains("ch") || filenameLower.contains("chapter") {
                contentType = .manga
            } else {
                contentType = .comic
            }
        }
        
        // 2. Generate unique filename inside sandbox
        let bookID = UUID()
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let relativePath = "\(librarySubdir)/\(bookID).\(fileExtension)"
        let destinationURL = documentsDir.appendingPathComponent(relativePath)
        
        // 3. Copy file to Documents folder
        try fileManager.copyItem(at: url, to: destinationURL)
        
        // 4. Calculate metadata & page counts
        let fileSize = try fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 ?? 0
        let pageCount = try await calculatePageCount(for: destinationURL, type: contentType)
        let title = url.deletingPathExtension().lastPathComponent
        
        // Extract Series name if possible
        let (series, volume) = parseSeriesAndVolume(from: title)
        
        // 5. Extract Cover Thumbnail
        if let coverData = await BetaArchiveService.shared.extractCover(from: destinationURL, contentType: contentType) {
            let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let coverURL = cachesDir.appendingPathComponent(coverSubdir).appendingPathComponent("\(bookID).jpg")
            try? coverData.write(to: coverURL, options: .atomic)
        }
        
        // 6. Save Model to SwiftData
        let newBook = BetaBook(
            id: bookID,
            title: title,
            filePath: relativePath,
            contentType: contentType,
            fileSize: fileSize,
            pageCount: pageCount,
            seriesName: series,
            volumeNumber: volume
        )
        
        modelContext.insert(newBook)
        try modelContext.save()
    }
    
    /// Deletes a book physically and from SwiftData
    public func deleteBook(_ book: BetaBook) {
        // Delete Book File
        let fileURL = book.resolvedURL
        try? fileManager.removeItem(at: fileURL)
        
        // Delete Cover Image
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let coverURL = cachesDir.appendingPathComponent(coverSubdir).appendingPathComponent("\(book.id).jpg")
        try? fileManager.removeItem(at: coverURL)
        
        // Delete Database Record
        modelContext.delete(book)
        try? modelContext.save()
        
        // Refresh local list
        fetchBooks()
    }
    
    // MARK: - Metadata Parsers
    
    private func calculatePageCount(for url: URL, type: BetaContentType) async throws -> Int {
        switch type {
        case .pdf:
            guard let doc = PDFDocument(url: url) else { return 0 }
            return doc.pageCount
        case .comic, .manga:
            let ext = url.pathExtension.lowercased()
            if ["cbr", "rar"].contains(ext) {
                guard let archive = try? Unrar.Archive(fileURL: url),
                      let entries = try? archive.entries() else { return 0 }
                return entries.filter { entry in
                    let filename = (entry.fileName as NSString).lastPathComponent
                    let ext = (filename as NSString).pathExtension.lowercased()
                    return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) && !entry.directory && !entry.fileName.contains("__MACOSX")
                }.count
            } else {
                guard let archive = try? Archive(url: url, accessMode: .read) else { return 0 }
                return archive.filter { entry in
                    let filename = (entry.path as NSString).lastPathComponent
                    let ext = (filename as NSString).pathExtension.lowercased()
                    return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) && !entry.path.contains("__MACOSX")
                }.count
            }
        case .epub:
            // Count number of spine item refs in EPUB
            guard let archive = try? Archive(url: url, accessMode: .read) else { return 0 }
            guard let containerEntry = archive["META-INF/container.xml"] else { return 0 }
            var containerData = Data()
            _ = try? archive.extract(containerEntry) { chunk in containerData.append(chunk) }
            
            guard let opfPath = parseOPFPath(from: containerData) else { return 0 }
            guard let opfEntry = archive[opfPath] else { return 0 }
            var opfData = Data()
            _ = try? archive.extract(opfEntry) { chunk in opfData.append(chunk) }
            
            let parser = SpineXMLParser(data: opfData)
            parser.parse()
            return max(1, parser.spineItemCount)
        }
    }
    
    private func parseOPFPath(from data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = OPFPathDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.opfPath
    }
    
    private func parseSeriesAndVolume(from title: String) -> (seriesName: String?, volumeNumber: String?) {
        // Regex patterns to capture "Volume X", "Vol. X", "Vol X", "Ch X", "#X"
        let pattern = #"(?i)(.*?)\s*(?:volume|vol\.?|ch\.?|chapter|#)\s*(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return (nil, nil) }
        
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        if let match = regex.firstMatch(in: title, options: [], range: range) {
            let nsTitle = title as NSString
            let seriesRange = match.range(at: 1)
            let volRange = match.range(at: 2)
            
            var series = nsTitle.substring(with: seriesRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let volume = nsTitle.substring(with: volRange).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Clean up trailing punctuation in series name
            if series.hasSuffix("-") || series.hasSuffix("_") || series.hasSuffix(",") {
                series.removeLast()
            }
            series = series.trimmingCharacters(in: .whitespacesAndNewlines)
            
            return (series.isEmpty ? nil : series, volume.isEmpty ? nil : volume)
        }
        
        return (nil, nil)
    }
}

// MARK: - XML Delegates

private class OPFPathDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName.lowercased() == "rootfile", let path = attributes["full-path"] {
            opfPath = path
        }
    }
}

private class SpineXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    var spineItemCount = 0
    private var inSpine = false
    
    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }
    
    func parse() {
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let lower = name.lowercased()
        
        if lower == "spine" {
            inSpine = true
        } else if inSpine && lower == "itemref" {
            spineItemCount += 1
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name.lowercased() == "spine" {
            inSpine = false
        }
    }
}

import Foundation
import ZIPFoundation

/// Writes `PDFMetadata` back into a `ComicInfo.xml` file inside a CBZ archive.
/// This makes tagging and organization portable across devices and apps.
struct ComicInfoWriter {
    
    /// Generates a `ComicInfo.xml` string from `PDFMetadata`
    static func generateXML(from metadata: PDFMetadata) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        xml += "<ComicInfo xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n"
        
        func appendNode(_ name: String, _ value: String?) {
            guard let val = value, !val.isEmpty else { return }
            // Basic XML escaping
            let escaped = val
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            
            xml += "  <\(name)>\(escaped)</\(name)>\n"
        }
        
        appendNode("Title", metadata.title)
        appendNode("Series", metadata.series)
        appendNode("Number", metadata.issueNumber)
        appendNode("Volume", metadata.volume)
        appendNode("Summary", metadata.summary)
        appendNode("Writer", metadata.writer)
        appendNode("Penciller", metadata.penciller)
        appendNode("Publisher", metadata.publisher)
        
        if let tags = metadata.tags, !tags.isEmpty {
            appendNode("Tags", tags.joined(separator: ", "))
        }
        
        if let pubDate = metadata.publicationDate {
            let cal = Calendar.current
            let year = cal.component(.year, from: pubDate)
            let month = cal.component(.month, from: pubDate)
            let day = cal.component(.day, from: pubDate)
            
            appendNode("Year", "\(year)")
            appendNode("Month", "\(month)")
            appendNode("Day", "\(day)")
        }
        
        if metadata.isManga {
            xml += "  <Manga>Yes</Manga>\n"
        }
        
        xml += "</ComicInfo>"
        return xml
    }
    
    /// Injects `ComicInfo.xml` into the specified CBZ archive.
    /// - Parameters:
    ///   - metadata: The metadata to serialize.
    ///   - archiveURL: The `file://` URL pointing to the `.cbz` file.
    static func write(metadata: PDFMetadata, to archiveURL: URL) async throws {
        // Run ZIP modifications predictably in background
        try await Task.detached(priority: .background) {
            let xmlString = generateXML(from: metadata)
            guard let xmlData = xmlString.data(using: .utf8) else {
                throw NSError(domain: "ComicInfoWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode XML data."])
            }
            
            // Read-Write Archive
            guard let archive = try? Archive(url: archiveURL, accessMode: .update) else {
                throw NSError(domain: "ComicInfoWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open archive for updating."])
            }
            
            // Note: ZIPFoundation `remove` by entry is tricky.
            // A safer approach is to check if it exists, remove it, then add the new one.
            if let existingEntry = archive.first(where: { $0.path.lowercased() == "comicinfo.xml" }) {
                do {
                    try archive.remove(existingEntry)
                } catch {
                    Logger.shared.log("Failed to remove old ComicInfo.xml: \(error)", category: "Metadata", type: .warning)
                }
            }
            
            do {
                try archive.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(xmlData.count), provider: { position, size in
                    return xmlData.subdata(in: Int(position)..<Int(position) + size)
                })
                Logger.shared.log("Successfully wrote ComicInfo.xml to \(archiveURL.lastPathComponent)", category: "Metadata")
            } catch {
                throw NSError(domain: "ComicInfoWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to add new ComicInfo.xml entry. \(error.localizedDescription)"])
            }
        }.value
    }
}

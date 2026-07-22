import Foundation

enum CitationStyle: String, CaseIterable, Identifiable {
    case apa = "APA"
    case chicago = "Chicago"
    case mla = "MLA"
    
    var id: String { rawValue }
}

struct CitationFormatter {
    static func format(annotation: SDAnnotation, style: CitationStyle = .apa) -> String {
        let author = annotation.readwiseAuthor ?? "Unknown Author"
        let title = annotation.readwiseBookTitle ?? "Untitled Work"
        let page = annotation.pageIndex + 1
        let year = Calendar.current.component(.year, from: annotation.createdAt)
        let text = annotation.selectedText ?? annotation.noteText ?? ""
        
        switch style {
        case .apa:
            return "\"\(text)\" (\(author), \(year), p. \(page))."
        case .chicago:
            return "\"\(text)\" (\(author), *\(title)*, \(page))."
        case .mla:
            return "\"\(text)\" (\(author) \(page))."
        }
    }
    
    static func bibliographyEntry(annotation: SDAnnotation, style: CitationStyle = .apa) -> String {
        let author = annotation.readwiseAuthor ?? "Unknown Author"
        let title = annotation.readwiseBookTitle ?? "Untitled Work"
        let year = Calendar.current.component(.year, from: annotation.createdAt)
        
        switch style {
        case .apa:
            return "\(author) (\(year)). *\(title)*."
        case .chicago:
            return "\(author). *\(title)*. \(year)."
        case .mla:
            return "\(author). *\(title)*, \(year)."
        }
    }
}

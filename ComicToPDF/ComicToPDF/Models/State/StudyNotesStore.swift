import Foundation
import Combine

class StudyNotesStore: ObservableObject {
    static let shared = StudyNotesStore()
    
    @Published var notes: String = ""
    private var currentBookID: String?
    
    private func getNotesURL(for bookID: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let studyDir = docs.appendingPathComponent("StudyNotes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: studyDir.path) {
            try? FileManager.default.createDirectory(at: studyDir, withIntermediateDirectories: true)
        }
        return studyDir.appendingPathComponent("\(bookID)_notes.md")
    }
    
    func loadNotes(for bookID: String) {
        self.currentBookID = bookID
        let url = getNotesURL(for: bookID)
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            self.notes = text
        } else {
            self.notes = ""
        }
    }
    
    func saveNotes() {
        guard let bookID = currentBookID else { return }
        let url = getNotesURL(for: bookID)
        try? notes.write(to: url, atomically: true, encoding: .utf8)
    }
    
    func appendHighlight(_ highlight: String, chapter: String = "") {
        let prefix = notes.isEmpty ? "" : "\n\n"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let chapterString = chapter.isEmpty ? "" : " (\(chapter))"
        let newEntry = "\(prefix)> \"\(highlight)\"\n> — *Captured \(timestamp)*\(chapterString)"
        
        self.notes += newEntry
        self.saveNotes()
    }
}

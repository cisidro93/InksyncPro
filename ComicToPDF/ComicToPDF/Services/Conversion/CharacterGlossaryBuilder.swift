import Foundation
import SwiftData
import SwiftUI

@MainActor
final class CharacterGlossaryBuilder {
    static let shared = CharacterGlossaryBuilder()
    private init() {}
    
    func buildGlossaryHTML(seriesIDString: String?, seriesName: String?, issueNumber: Int?) -> String? {
        let context = InksyncProApp.sharedModelContainer.mainContext
        
        let allCharacters = (try? context.fetch(FetchDescriptor<SDCharacterNode>())) ?? []
        let allAppearances = (try? context.fetch(FetchDescriptor<SDCharacterAppearance>())) ?? []
        let allRelationships = (try? context.fetch(FetchDescriptor<SDRelationship>())) ?? []
        
        var targetCharacters: [SDCharacterNode] = []
        
        if let idStr = seriesIDString, let uuid = UUID(uuidString: idStr) {
            let appearances = allAppearances.filter { $0.seriesID == uuid }
            let characterIDs = Set(appearances.map { $0.characterID })
            targetCharacters = allCharacters.filter { characterIDs.contains($0.id) }
        }
        
        // Fallback to series name match or all characters if empty
        if targetCharacters.isEmpty {
            if let name = seriesName, !name.isEmpty {
                targetCharacters = allCharacters.filter { char in
                    char.name.localizedCaseInsensitiveContains(name) ||
                    (char.bio?.localizedCaseInsensitiveContains(name) ?? false)
                }
            }
        }
        
        if targetCharacters.isEmpty {
            targetCharacters = allCharacters
        }
        
        // If still empty, no glossary to embed
        guard !targetCharacters.isEmpty else { return nil }
        
        let currentIssue = issueNumber ?? 1
        
        var html = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>Character Glossary</title>
          <style>
            body {
              background-color: #0c0c14;
              color: #e2e8f0;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
              padding: 24px;
              margin: 0;
            }
            h1 {
              color: #a855f7;
              font-size: 22px;
              border-bottom: 2px solid #3b2d54;
              padding-bottom: 12px;
              margin-bottom: 24px;
              text-align: center;
              font-weight: 800;
              letter-spacing: -0.02em;
            }
            .character-card {
              background-color: #151525;
              border: 1px solid #2d2d44;
              border-radius: 12px;
              padding: 18px;
              margin-bottom: 18px;
              box-shadow: 0 4px 6px rgba(0,0,0,0.15);
            }
            .char-name {
              color: #ffffff;
              font-size: 18px;
              font-weight: 700;
              margin-bottom: 4px;
            }
            .first-app {
              font-size: 11px;
              color: #94a3b8;
              margin-bottom: 12px;
              text-transform: uppercase;
              letter-spacing: 0.05em;
              font-weight: 600;
            }
            .bio {
              font-size: 13px;
              color: #cbd5e1;
              line-height: 1.6;
              margin-bottom: 14px;
            }
            .relations-title {
              font-size: 12px;
              color: #a855f7;
              font-weight: 700;
              margin-bottom: 8px;
              text-transform: uppercase;
              letter-spacing: 0.03em;
            }
            .relation-item {
              font-size: 12px;
              color: #cbd5e1;
              background-color: #0c0c14;
              padding: 8px 12px;
              border-radius: 6px;
              margin-bottom: 6px;
              border-left: 3px solid #a855f7;
            }
            .relation-type {
              font-weight: 600;
              color: #f3e8ff;
            }
          </style>
        </head>
        <body>
          <h1>Cast &amp; Character Glossary</h1>
        """
        
        for char in targetCharacters {
            html += """
              <div class="character-card">
                <div class="char-name">\(char.name.xmlEscaped())</div>
            """
            
            if let firstApp = char.firstAppearanceIssue, !firstApp.isEmpty {
                html += "    <div class=\"first-app\">First Appearance: \(firstApp.xmlEscaped())</div>\n"
            } else {
                html += "    <div class=\"first-app\">Character Dossier</div>\n"
            }
            
            if let bio = char.bio, !bio.isEmpty {
                html += "    <div class=\"bio\">\(bio.xmlEscaped())</div>\n"
            }
            
            let relations = allRelationships.filter { relation in
                let isRelated = relation.sourceCharacterID == char.id || relation.targetCharacterID == char.id
                let isVisible = relation.visibleAfterIssueNumber <= currentIssue
                return isRelated && isVisible
            }
            
            if !relations.isEmpty {
                html += "    <div class=\"relations-title\">Known Relationships</div>\n"
                for rel in relations {
                    let otherID = (rel.sourceCharacterID == char.id) ? rel.targetCharacterID : rel.sourceCharacterID
                    if let otherChar = allCharacters.first(where: { $0.id == otherID }) {
                        html += """
                            <div class="relation-item">
                              <span class="relation-type">\(rel.type.xmlEscaped())</span> with \(otherChar.name.xmlEscaped())
                            </div>
                        """
                    }
                }
            }
            
            html += "  </div>\n"
        }
        
        html += """
        </body>
        </html>
        """
        return html
    }
}

import os
import re

file_path = r"c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\BookReaderEngine.swift"

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Replace block 1
replacement1 = """        var rawHTML: String?
        var usedEncoding: String.Encoding = .utf8
        if let html = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            rawHTML = html
        } else if let data = try? Data(contentsOf: url) {
            rawHTML = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .ascii)
        }
        
        if var html = rawHTML {
            let pattern = "<meta[^>]*charset[^>]*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                html = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<meta charset=\\"utf-8\\">")
            }
            self.currentChapterHTML = html
            self.isLoading = false
        }"""

pattern1 = re.compile(re.escape("if let html = try? String(contentsOf: url, encoding: .utf8) {") + r"\s*" +
                      re.escape("self.currentChapterHTML = html") + r"\s*" +
                      re.escape("self.isLoading = false") + r"\s*" +
                      re.escape("}"))

content = pattern1.sub(replacement1, content)

# Replace block 2
pattern2 = re.compile(re.escape("column-count: 1 !important;") + r"\s*" +
                      re.escape("}") + r"\s*" +
                      re.escape("img { max-width: 100% !important; height: auto !important; }") + r"\s*" +
                      re.escape(".inksync-highlight { background-color: #ffd700; color: #000; border-radius: 3px; }"))

replacement2 = """column-count: 1 !important;
                    /* Premium enhancements */
                    text-align: justify !important;
                    -webkit-hyphens: auto !important;
                    hyphens: auto !important;
                }
                img { max-width: 100% !important; height: auto !important; border-radius: 4px; object-fit: contain; }
                .inksync-highlight { background-color: #ffd700; color: #000; border-radius: 3px; }"""

content = pattern2.sub(replacement2, content)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
print("Regex replace complete!")

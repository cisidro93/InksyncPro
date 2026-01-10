// ============================================================================
// EPUB DIAGNOSTIC TOOL
// ============================================================================
// Use this to diagnose what's in your EPUB and why strips appear
// ============================================================================

import UIKit
import ZIPFoundation

class EPUBDiagnostics {
    
    static func diagnoseEPUB(_ epubURL: URL) {
        print("\n" + String(repeating: "=", count: 70))
        print("🔍 EPUB DIAGNOSTIC REPORT")
        print(String(repeating: "=", count: 70))
        print("File: \(epubURL.lastPathComponent)")
        print("Size: \(formatBytes(getFileSize(epubURL)))")
        
        // Extract EPUB
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("epub_diagnosis")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        do {
            try FileManager.default.unzipItem(at: epubURL, to: tempDir)
            print("✅ EPUB extracted successfully")
            
            // Analyze images
            var images: [(String, CGSize, Double, String)] = []
            
            if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    let ext = fileURL.pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "gif"].contains(ext) {
                        if let image = UIImage(contentsOfFile: fileURL.path) {
                            let aspect = image.size.width / image.size.height
                            let type = aspect > 2.0 ? "⚠️ STRIP" : "✅ PAGE"
                            images.append((fileURL.lastPathComponent, image.size, aspect, type))
                        }
                    }
                }
            }
            
            images.sort { $0.0 < $1.0 }
            
            print("\n📊 IMAGE ANALYSIS:")
            print("Total images found: \(images.count)")
            
            let stripCount = images.filter { $0.3.contains("STRIP") }.count
            let pageCount = images.filter { $0.3.contains("PAGE") }.count
            
            print("  - Full pages: \(pageCount)")
            print("  - Strips: \(stripCount)")
            
            if stripCount > 0 {
                print("\n⚠️ DIAGNOSIS: EPUB CONTAINS HORIZONTAL STRIPS!")
                print("  This is why your split/conversion creates sliced pages.")
                print("  Recommended strips per page: \(calculateRecommendedStripsPerPage(images.count))")
                print("  Estimated actual pages: \(images.count / calculateRecommendedStripsPerPage(images.count))")
            } else {
                print("\n✅ DIAGNOSIS: EPUB contains full pages (no strips)")
            }
            
            // Show sample images
            print("\n📷 SAMPLE IMAGES (first 10):")
            for (name, size, aspect, type) in images.prefix(10) {
                print("  \(type) - \(name)")
                print("      Size: \(Int(size.width))x\(Int(size.height))")
                print("      Aspect: \(String(format: "%.2f", aspect)) (width/height)")
            }
            
            if images.count > 10 {
                print("  ... and \(images.count - 10) more images")
            }
            
            // Check XHTML files
            print("\n📝 XHTML FILES:")
            var xhtmlCount = 0
            if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if ["xhtml", "html"].contains(fileURL.pathExtension.lowercased()) {
                        xhtmlCount += 1
                    }
                }
            }
            print("  Total XHTML files: \(xhtmlCount)")
            
            print(String(repeating: "=", count: 70) + "\n")
            
        } catch {
            print("❌ Failed to extract EPUB: \(error)")
        }
    }
    
    private static func calculateRecommendedStripsPerPage(_ totalImages: Int) -> Int {
        for strips in [10, 8, 7, 6, 5, 4] {
            if totalImages % strips == 0 {
                return strips
            }
        }
        return 6
    }
    
    private static func getFileSize(_ url: URL) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return attrs[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

import UIKit
import ZIPFoundation

class DebugUtils {
    
    static func debugConversionPipeline(_ cbzURL: URL) {
        print("\n" + String(repeating: "=", count: 60))
        print("🔍 CONVERSION PIPELINE DEBUGGER")
        print(String(repeating: "=", count: 60))
        
        // Step 1: Check original CBZ
        print("\n📦 STEP 1: Analyzing original CBZ")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("debug_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        do {
            try FileManager.default.unzipItem(at: cbzURL, to: tempDir)
            
            var images: [(String, CGSize, String)] = []
            if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in enumerator {
                    if ["jpg", "jpeg", "png"].contains(fileURL.pathExtension.lowercased()) {
                        if let image = UIImage(contentsOfFile: fileURL.path) {
                            let aspect = image.size.width / image.size.height
                            let type = aspect > 2.0 ? "⚠️ STRIP" : "✅ FULL PAGE"
                            images.append((fileURL.lastPathComponent, image.size, type))
                        }
                    }
                }
            }
            
            print("Total images in CBZ: \(images.count)")
            for (name, size, type) in images.sorted(by: { $0.0 < $1.0 }).prefix(10) {
                print("  \(type) - \(name): \(Int(size.width))x\(Int(size.height))")
            }
            
            if images.count > 10 {
                print("  ... and \(images.count - 10) more")
            }
            
            // Diagnosis
            let stripCount = images.filter { $0.2.contains("STRIP") }.count
            if stripCount > 0 {
                print("\n⚠️ DIAGNOSIS: CBZ already contains STRIPS!")
                print("   The source file is pre-sliced. You need to reconstruct pages.")
            } else {
                print("\n✅ DIAGNOSIS: CBZ contains full pages")
                print("   Problem is happening DURING conversion")
            }
            
        } catch {
            print("❌ Error: \(error)")
        }
        
        print(String(repeating: "=", count: 60) + "\n")
    }
}

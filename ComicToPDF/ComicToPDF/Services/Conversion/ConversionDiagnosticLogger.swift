import Foundation
import UIKit

/// Enterprise Conversion Diagnostic Logger.
/// Tracks per-file and per-page byte sizes, preset dimensions, quality parameters,
/// container compression output, and flags file size expansion/bloat.
struct ConversionDiagnosticLogger {
    
    struct ConversionMetrics: Sendable {
        let jobTitle: String
        let preset: CompressionPreset
        let inputFilesCount: Int
        let totalInputBytes: Int64
        var pageMetrics: [PageMetric] = []
        var totalOutputBytes: Int64 = 0
        var outputURL: URL? = nil
        let startTime: Date = Date()
        
        struct PageMetric: Sendable {
            let pageIndex: Int
            let originalBytes: Int64
            let compressedBytes: Int64
            let originalSize: CGSize
            let outputSize: CGSize
            let format: String
        }
    }
    
    /// Call at the start of any conversion process (single file, convert & merge, omnibus, etc.)
    static func logStart(jobTitle: String, settings: ConversionSettings, sourceFiles: [URL]) -> ConversionMetrics {
        let preset = settings.compressionQuality
        let totalInputBytes = sourceFiles.reduce(Int64(0)) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            return sum + Int64(size)
        }
        
        let inputFormatted = ByteCountFormatter.string(fromByteCount: totalInputBytes, countStyle: .file)
        let maxDimStr = preset.maxDimension.map { "\(Int($0))px" } ?? "Original"
        let qualityPct = Int(preset.value * 100)
        
        let fileDetails = sourceFiles.prefix(6).map { url in
            let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0)
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "   • \(url.lastPathComponent) (\(formatted))"
        }.joined(separator: "\n")
        let moreFilesStr = sourceFiles.count > 6 ? "\n   ... and \(sourceFiles.count - 6) more file(s)" : ""
        
        let logMsg = """
        ============================================================
        🚀 [CONVERSION DIAGNOSTIC START]
        📋 Job: \(jobTitle)
        ⚙️ Preset: \(preset.displayName)
        📊 Target Quality: \(qualityPct)% JPEG | Max Dim: \(maxDimStr) | sRGB Forced
        📁 Total Input Files: \(sourceFiles.count) (\(inputFormatted))
        \(fileDetails)\(moreFilesStr)
        ============================================================
        """
        
        Logger.shared.log(logMsg, category: "Conversion", type: .info)
        return ConversionMetrics(jobTitle: jobTitle, preset: preset, inputFilesCount: sourceFiles.count, totalInputBytes: totalInputBytes)
    }
    
    /// Call for each processed image page
    static func logPage(metrics: inout ConversionMetrics, pageIndex: Int, origBytes: Int64, compressedBytes: Int64, origSize: CGSize, outSize: CGSize, format: String) {
        let pMetric = ConversionMetrics.PageMetric(
            pageIndex: pageIndex,
            originalBytes: origBytes,
            compressedBytes: compressedBytes,
            originalSize: origSize,
            outputSize: outSize,
            format: format
        )
        metrics.pageMetrics.append(pMetric)
        
        let isBloated = origBytes > 0 && compressedBytes > (origBytes * 11 / 10) // > 110% of input
        let ratio = origBytes > 0 ? (Double(compressedBytes) / Double(origBytes)) * 100.0 : 100.0
        let origFormatted = ByteCountFormatter.string(fromByteCount: origBytes, countStyle: .file)
        let compFormatted = ByteCountFormatter.string(fromByteCount: compressedBytes, countStyle: .file)
        
        let statusSymbol = isBloated ? "⚠️ BLOAT DETECTED" : "✅ OPTIMIZED"
        let logType: LogType = isBloated ? .warning : .info
        
        // Log sample pages (first 3, every 20th page, and any bloated page)
        if pageIndex <= 3 || pageIndex % 20 == 0 || isBloated {
            let sampleMsg = "📄 [Page \(pageIndex)] \(statusSymbol) | Src: \(Int(origSize.width))x\(Int(origSize.height)) (\(origFormatted)) -> Out: \(Int(outSize.width))x\(Int(outSize.height)) (\(compFormatted) \(format.uppercased())) [\(String(format: "%.1f", ratio))% of src]"
            Logger.shared.log(sampleMsg, category: "Conversion", type: logType)
        }
    }
    
    /// Call upon completion of container packaging (EPUB zip or PDF write)
    static func logCompletion(metrics: ConversionMetrics, outputURL: URL) {
        let finalOutputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? UInt64).map { Int64($0) } ?? 0
        let inputFormatted = ByteCountFormatter.string(fromByteCount: metrics.totalInputBytes, countStyle: .file)
        let outputFormatted = ByteCountFormatter.string(fromByteCount: finalOutputBytes, countStyle: .file)
        
        let expansionRatio = metrics.totalInputBytes > 0 ? Double(finalOutputBytes) / Double(metrics.totalInputBytes) : 1.0
        let percentChange = (expansionRatio - 1.0) * 100.0
        let elapsed = Date().timeIntervalSince(metrics.startTime)
        
        let isExpanded = expansionRatio > 1.15
        let statusSymbol: String
        if isExpanded {
            statusSymbol = "❌ BLOAT WARNING (\(String(format: "%.2fx", expansionRatio)) size expansion!)"
        } else if percentChange < 0 {
            statusSymbol = "✅ OPTIMIZED (\(String(format: "%.1f", abs(percentChange)))% size reduction)"
        } else {
            statusSymbol = "✅ BALANCED (\(String(format: "%.1f", percentChange))% size change)"
        }
        
        let logType: LogType = isExpanded ? .warning : .success
        
        let summaryMsg = """
        ============================================================
        🏁 [CONVERSION DIAGNOSTIC SUMMARY]
        📋 Job: \(metrics.jobTitle)
        ⚙️ Preset: \(metrics.preset.displayName)
        ⏱️ Time Elapsed: \(String(format: "%.2f", elapsed))s | Total Pages: \(metrics.pageMetrics.count)
        📊 Raw Input Total:  \(inputFormatted) (\(metrics.totalInputBytes) bytes)
        📊 Output File Size: \(outputFormatted) (\(finalOutputBytes) bytes)
        📈 Compression Result: \(statusSymbol)
        📁 Output File: \(outputURL.lastPathComponent)
        ============================================================
        """
        
        Logger.shared.log(summaryMsg, category: "Conversion", type: logType)
    }
}

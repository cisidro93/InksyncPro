import Foundation
import UIKit
import Combine
import ZIPFoundation

/// Resolves the 'God Object' bottleneck by handling intensive O(N) file system
/// enumeration strictly off the Main Thread.
actor LibraryScanner {
    static let shared = LibraryScanner()

    func scanLibrary(addedByMode: AppUIMode? = nil, manager: ConversionManager) async {
        let fileManager = FileManager.default
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let inboxDir  = appSupport.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        let docDir    = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory

        var newPDFs: [ConvertedPDF] = []
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .fileSizeKey]

        let currentPaths = await MainActor.run {
            manager.convertedPDFs.map { $0.url.lastPathComponent }
        }
        let pathSet = Set(currentPaths)

        // Scan both the Documents directory and the Wi-Fi transfer Inbox
        let dirsToScan = [docDir, inboxDir]

        for scanDir in dirsToScan {
            guard let enumerator = fileManager.enumerator(
                at: scanDir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }

            var filesSinceYield = 0
            while let fileURL = enumerator.nextObject() as? URL {
                // ✅ PERF: yield every 25 files instead of every single file.
                // Task.yield() is a cooperative scheduling checkpoint — calling it
                // for every file in a 2000-file library creates 2000 unnecessary
                // context switches and makes the scan visibly slower.
                filesSinceYield += 1
                if filesSinceYield >= 25 {
                    filesSinceYield = 0
                    await Task.yield()
                }

                if fileURL.path.contains("Recovered_Vault") || fileURL.path.contains("LibraryVault") { continue }

                let ext = fileURL.pathExtension.lowercased()
                guard ["pdf", "cbz", "zip", "epub", "cbr", "cbt"].contains(ext) else { continue }

                let filename = fileURL.lastPathComponent
                guard !pathSet.contains(filename) else { continue }

                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

                // Infer content type from extension:
                // • EPUB → always a book (e-reader format)
                // • PDF  → book by default (most PDFs are documents/books, not comics)
                // • CBZ/CBR/CBT/ZIP → comic (these are the canonical comic archive formats)
                let inferredContentType: ContentType
                switch ext {
                case "epub", "pdf":
                    inferredContentType = .book
                case "cbz", "cbr", "cbt", "zip":
                    inferredContentType = .comic
                default:
                    inferredContentType = .comic
                }

                var newPDF = ConvertedPDF(
                    name: filename, url: fileURL,
                    pageCount: 0, fileSize: fileSize,
                    metadata: PDFMetadata(title: filename),
                    contentType: inferredContentType
                )
                newPDF.addedByMode = addedByMode ?? .pro
                newPDFs.append(newPDF)
            }
        }

        let finalNewPDFs = newPDFs
        if !finalNewPDFs.isEmpty {
            await MainActor.run {
                manager.convertedPDFs.append(contentsOf: finalNewPDFs)
                Logger.shared.log("Library Scanned: Found \(finalNewPDFs.count) new files (mode: \(addedByMode?.rawValue ?? "Pro"))", category: "Library")
                manager.saveLibrary()
            }
        }

        // ── Cover + page-count backfill ──────────────────────────────────────
        // ✅ PERF: Was serial — one cover then one page count, one file at a time.
        // Now uses a TaskGroup capped at 4 concurrent slots.
        // Each slot fetches the cover and page count for one file, then the slot
        // opens for the next file. This keeps CPU/IO busy without flooding the
        // main actor queue with 500 simultaneous tasks.

        let pdfsToProcess = await MainActor.run {
            manager.convertedPDFs.filter { $0.pageCount == 0 }
        }

        if !pdfsToProcess.isEmpty {
            // Materialise the work list as a plain value-type array before crossing into
            // Task.detached isolation. The original code captured a mutable iterator and an
            // Int counter by reference across actor boundaries — a data race in strict concurrency.
            let workItems: [(id: UUID, url: URL)] = pdfsToProcess.map { ($0.id, $0.url) }
            let perfClass = ProcessInfo.processInfo.performanceClass
            let maxConcurrency = perfClass == .low ? 2 : 4

            Task.detached(priority: .background) {
                await withTaskGroup(of: (UUID, Int)?.self) { group in
                    var nextIndex = 0

                    // Seed initial slots
                    func enqueueNext() {
                        guard nextIndex < workItems.count else { return }
                        let item = workItems[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            let image = PhysicalFileSystemRouter.extractCoverImageStatic(from: item.url)
                            if let image, let jpegData = image.jpegData(compressionQuality: 0.7) {
                                let capturedID = item.id
                                await MainActor.run {
                                    // Look up the full ConvertedPDF on MainActor — saveCoverImage
                                    // requires the ConvertedPDF object, not just a UUID.
                                    if let pdf = manager.convertedPDFs.first(where: { $0.id == capturedID }) {
                                        PhysicalFileSystemRouter.shared.saveCoverImage(
                                            jpegData, for: pdf, manager: manager)
                                    }
                                }
                            }
                            let count = PhysicalFileSystemRouter.getPageCountStatic(from: item.url)
                            return count > 0 ? (item.id, count) : nil
                        }
                    }

                    for _ in 0..<min(maxConcurrency, workItems.count) { enqueueNext() }

                    for await result in group {
                        if let (id, count) = result {
                            await MainActor.run {
                                if let idx = manager.convertedPDFs.firstIndex(where: { $0.id == id }) {
                                    manager.convertedPDFs[idx].pageCount = count
                                }
                            }
                        }
                        enqueueNext()
                    }
                }
                await MainActor.run { manager.saveLibrary() }
            }
        }

        // ── Deduplication & ghost-file pruning ───────────────────────────────
        let allPDFs = await MainActor.run { manager.convertedPDFs }
        
        var uniquePDFs: [ConvertedPDF] = []
        var seenNames = Set<String>()
        var missingIDs = Set<UUID>()
        
        var didRepairURLs = false

        // PERF D-M1: yield every 50 files so iCloud-backed fileExists calls
        // (which can block waiting for ubiquity metadata) don't stall the actor
        // thread and delay the first library render.
        var pruneYieldCount = 0
        for var pdf in allPDFs {
            pruneYieldCount += 1
            if pruneYieldCount % 50 == 0 { await Task.yield() }

            if seenNames.contains(pdf.url.lastPathComponent) {
                missingIDs.insert(pdf.id)
                continue
            }
            seenNames.insert(pdf.url.lastPathComponent)

            if pdf.isLinked {
                uniquePDFs.append(pdf)
                continue
            }

            if fileManager.fileExists(atPath: pdf.url.path) {
                uniquePDFs.append(pdf)
                continue
            }

            // Sandbox-Shift Repair Logic
            var repairedURL: URL? = nil
            let oldPath = pdf.url.path

            if let docRange = oldPath.range(of: "/Documents/") {
                let relPath = String(oldPath[docRange.upperBound...])
                let checkURL = docDir.appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: checkURL.path) {
                    repairedURL = checkURL
                }
            }
            if repairedURL == nil, let inboxRange = oldPath.range(of: "/InksyncVault/Inbox/") {
                let relPath = String(oldPath[inboxRange.upperBound...])
                let checkURL = inboxDir.appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: checkURL.path) {
                    repairedURL = checkURL
                }
            }

            // Fallback: Check root of Documents and Inbox
            if repairedURL == nil {
                let rootDoc = docDir.appendingPathComponent(pdf.url.lastPathComponent)
                let rootInbox = inboxDir.appendingPathComponent(pdf.url.lastPathComponent)
                if fileManager.fileExists(atPath: rootDoc.path) {
                    repairedURL = rootDoc
                } else if fileManager.fileExists(atPath: rootInbox.path) {
                    repairedURL = rootInbox
                }
            }

            if let newURL = repairedURL {
                pdf.url = newURL
                didRepairURLs = true
                uniquePDFs.append(pdf)
            } else {
                missingIDs.insert(pdf.id)
            }
        }

        let requiresPrune = !missingIDs.isEmpty || didRepairURLs
        if requiresPrune {
            await MainActor.run {
                manager.convertedPDFs = uniquePDFs
                Logger.shared.log("Library Pruned: Repaired sandbox-shifted URLs and removed \(missingIDs.count) missing files", category: "Library")
                manager.saveLibrary()
            }
        }
    }
}

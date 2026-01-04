
    // MARK: - Page Manager Logic

    func deletePages(from pdf: ConvertedPDF, pagesToDelete: Set<Int>) async throws {
        // 1. Validation
        guard pdf.url.pathExtension.lowercased() == "pdf" else {
            throw NSError(domain: "PageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Page deletion is currently only supported for PDF files."])
        }
        
        await MainActor.run { self.processingStatus = "Removing pages..." }
        
        let sourceURL = pdf.url
        let fileManager = FileManager.default
        
        // 2. Create Temp Output
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempOutput = tempDir.appendingPathComponent("temp_trimmed.pdf")
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // 3. Load PDF
                    guard let document = PDFDocument(url: sourceURL) else {
                        throw NSError(domain: "PageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not load source PDF."])
                    }
                    
                    // 4. Rebuild PDF without deleted pages
                    let newDocument = PDFDocument()
                    var newIndex = 0
                    
                    for i in 0..<document.pageCount {
                        if !pagesToDelete.contains(i) {
                            if let page = document.page(at: i) {
                                newDocument.insert(page, at: newIndex)
                                newIndex += 1
                            }
                        }
                    }
                    
                    // 5. Save and Swap
                    if newDocument.write(to: tempOutput) {
                        // Replace original file safely
                        let backupURL = sourceURL.appendingPathExtension("bak")
                        try? fileManager.moveItem(at: sourceURL, to: backupURL)
                        
                        do {
                            try fileManager.moveItem(at: tempOutput, to: sourceURL)
                            try? fileManager.removeItem(at: backupURL) // Delete backup if successful
                            try? fileManager.removeItem(at: tempDir)
                            
                            // 6. Update Library Data
                            await MainActor.run {
                                self.processingStatus = "Pages removed!"
                                self.scanForPDFs() // Refreshes page count and file size in the list
                            }
                            continuation.resume()
                        } catch {
                            // Restore backup if move failed
                            try? fileManager.moveItem(at: backupURL, to: sourceURL)
                            throw error
                        }
                    } else {
                        throw NSError(domain: "PageManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write new PDF file."])
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // Helper used by PageManagerView
    func extractImages(from url: URL, progressHandler: @escaping (Double) -> Void) async throws -> [UIImage] {
        guard let document = PDFDocument(url: url) else { return [] }
        var images: [UIImage] = []
        let pageCount = document.pageCount
        
        for i in 0..<pageCount {
            if let page = document.page(at: i) {
                let pageRect = page.bounds(for: .mediaBox)
                // Use a reasonable thumbnail size to avoid memory issues with large PDFs
                let targetSize = CGSize(width: 300, height: 400) 
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                
                let image = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(CGRect(origin: .zero, size: targetSize))
                    
                    ctx.cgContext.translateBy(x: 0.0, y: targetSize.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    
                    // Scale page to fit target size
                    let scaleX = targetSize.width / pageRect.width
                    let scaleY = targetSize.height / pageRect.height
                    let scale = min(scaleX, scaleY)
                    
                    ctx.cgContext.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                images.append(image)
            }
            if i % 5 == 0 { progressHandler(Double(i) / Double(pageCount)) }
        }
        progressHandler(1.0)
        return images
    }

import UIKit
import ZIPFoundation

struct CBZProcessor {
    
    /// Processes and packages images into a CBZ archive according to ConversionSettings,
    /// and writes a ComicInfo.xml metadata descriptor.
    /// - Parameters:
    ///   - imageURLs: Ordered list of source image URLs.
    ///   - outputURL: Target path for the output `.cbz` archive.
    ///   - settings: User's selected `ConversionSettings`.
    ///   - coverOverrideData: Optional raw image data to replace the first page cover.
    ///   - progress: Progress update closure.
    static func processAndPackage(
        from imageURLs: [URL],
        to outputURL: URL,
        settings: ConversionSettings,
        coverOverrideData: Data?,
        progress: @escaping (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("CBZProc_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let totalCount = Double(imageURLs.count)
        var globalImageIndex = 0
        
        for (originalIndex, srcURL) in imageURLs.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            
            try autoreleasepool {
                guard let rawImage = UIImage(contentsOfFile: srcURL.path) else {
                    Logger.shared.log("CBZProcessor: Skipping unreadable image \(srcURL.lastPathComponent)", category: "Converter", type: .warning)
                    return
                }
                
                // A. Check for Webtoon Slicing or Spread Slicing
                var imagesToProcess: [UIImage] = []
                var isSliced = false
                
                let width = rawImage.size.width
                let height = rawImage.size.height
                
                if settings.splitWebtoon && height > width * 1.5 {
                    let slices = ImageProcessor.sliceWebtoon(image: rawImage, targetAspectRatio: 1.33)
                    if slices.count > 1 {
                        imagesToProcess = slices
                        isSliced = true
                    }
                } else if settings.splitSpreads && width > height * 1.1 {
                    let slices = ImageProcessor.sliceSpread(image: rawImage, isManga: settings.mangaMode)
                    if slices.count > 1 {
                        imagesToProcess = slices
                        isSliced = true
                    }
                }
                
                if !isSliced {
                    imagesToProcess = [rawImage]
                }
                
                // B. Process and compress each slice
                for slice in imagesToProcess {
                    var finalData = Data()
                    autoreleasepool {
                        // Apply cover override on first page if provided
                        let targetImage: UIImage
                        if globalImageIndex == 0, let coverData = coverOverrideData, let coverImg = UIImage(data: coverData) {
                            targetImage = coverImg
                        } else {
                            targetImage = slice
                        }
                        
                        let processedImage = ImageProcessor.process(
                            image: targetImage,
                            settings: settings,
                            isOddPage: globalImageIndex % 2 == 0
                        ) ?? targetImage
                        
                        // sRGB Color conversion + Jpeg compression
                        let jpegData = processedImage.jpegData(compressionQuality: settings.compressionQuality.value) ?? Data()
                        finalData = ImageProcessor.convertToSRGB(data: jpegData)
                    }
                    
                    if !finalData.isEmpty {
                        let dest = tempDir.appendingPathComponent(String(format: "page_%04d.jpg", globalImageIndex))
                        try finalData.write(to: dest)
                        globalImageIndex += 1
                    }
                }
                
                progress(Double(originalIndex + 1) / totalCount)
            }
        }
        
        // Stage 3: Zip and Exclude from Backup
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try await ZipUtilities.zipDirectory(tempDir, to: outputURL)
        PhysicalFileSystemRouter.excludeFromBackup(at: outputURL)
        
        // Stage 4: Inject metadata
        let metadata = PDFMetadata(
            title: outputURL.deletingPathExtension().lastPathComponent,
            isManga: settings.mangaMode
        )
        try await ComicInfoWriter.write(metadata: metadata, to: outputURL)
    }
}

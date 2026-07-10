import Foundation

/// Transactional helper to handle staging file manipulation safely without leaving partial/corrupt files.
public final class AtomicFileCoordinator {
    
    public enum FileError: Error {
        case sourceMissing
        case destinationCollision
        case integrityCheckFailed
        case transactionWriteFailed
    }
    
    /// Atomically imports a file from a staging directory to the target document folder.
    /// Stage 1: Copy source file to a temporary file in the target directory.
    /// Stage 2: Verify byte count integrity of the copied temporary file.
    /// Stage 3: Perform atomic replace of the destination file.
    /// Stage 4: Clean up source file if deletion is requested.
    public static func importFile(
        from source: URL,
        to destination: URL,
        useMoveIfStaged: Bool = true
    ) throws {
        let fileManager = FileManager.default
        
        // 1. Validate Source
        guard fileManager.fileExists(atPath: source.path) else {
            throw FileError.sourceMissing
        }
        
        let targetDirectory = destination.deletingLastPathComponent()
        
        // Ensure directory exists
        if !fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        }
        
        // 2. Setup temporary destination in the same directory (necessary for atomic replacement)
        let tempDestination = targetDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
        
        // 3. Stage 1: Copy to temp location
        do {
            try fileManager.copyItem(at: source, to: tempDestination)
        } catch {
            try? fileManager.removeItem(at: tempDestination)
            throw FileError.transactionWriteFailed
        }
        
        // 4. Stage 2: Verify size and presence of temporary staging file
        let sourceAttrs = try? fileManager.attributesOfItem(atPath: source.path)
        let tempAttrs = try? fileManager.attributesOfItem(atPath: tempDestination.path)
        
        let sourceSize = (sourceAttrs?[.size] as? Int64) ?? 0
        let tempSize = (tempAttrs?[.size] as? Int64) ?? 0
        
        guard sourceSize == tempSize && tempSize > 0 else {
            try? fileManager.removeItem(at: tempDestination)
            throw FileError.integrityCheckFailed
        }
        
        // 5. Stage 3: Replace file atomically
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tempDestination, options: [])
            } else {
                try fileManager.moveItem(at: tempDestination, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: tempDestination)
            throw FileError.transactionWriteFailed
        }
        
        // 6. Stage 4: Clean up source
        if useMoveIfStaged {
            try? fileManager.removeItem(at: source)
        }
    }
}

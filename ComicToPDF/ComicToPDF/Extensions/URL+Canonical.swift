import Foundation

extension URL {
    /// Fast in-memory path canonicalization that standardizes file URLs and strips sandbox prefixes
    /// (`/private/var/...` vs `/var/...`) without executing kernel `lstat` or `readlink` syscalls.
    @inlinable
    public var fastCanonicalPath: String {
        var p = self.standardizedFileURL.path
        if p.hasPrefix("/private/var/") {
            p = String(p.dropFirst(8)) // strips "/private"
        }
        return p.lowercased()
    }
}

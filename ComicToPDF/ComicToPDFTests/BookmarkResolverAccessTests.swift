import XCTest
@testable import InksyncPro

final class BookmarkResolverAccessTests: XCTestCase {

    func testResolveSandboxURLRemapsStaleContainerUUIDForDocuments() {
        let staleUUID = "12345678-ABCD-EF01-2345-6789ABCDEF01"
        let stalePath = "/var/mobile/Containers/Data/Application/\(staleUUID)/Documents/Comics/Batman_001.cbz"
        
        let resolved = LibraryFileRecord.resolveSandboxURL(stalePath)
        
        let currentDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        XCTAssertTrue(resolved.path.hasPrefix(currentDocs.path), "Resolved URL must point to the active sandbox Documents directory")
        XCTAssertEqual(resolved.lastPathComponent, "Batman_001.cbz")
    }

    func testResolveSandboxURLRemapsStaleContainerUUIDForApplicationSupport() {
        let staleUUID = "87654321-DCBA-10EF-5432-10FEDCBA9876"
        let stalePath = "/var/mobile/Containers/Data/Application/\(staleUUID)/Library/Application Support/InksyncVault/Inbox/Book.epub"
        
        let resolved = LibraryFileRecord.resolveSandboxURL(stalePath)
        
        let currentSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertTrue(resolved.path.hasPrefix(currentSupport.path), "Resolved URL must point to the active sandbox Application Support directory")
        XCTAssertEqual(resolved.lastPathComponent, "Book.epub")
    }

    func testResolvedAccessLifecycle() {
        let testURL = URL(fileURLWithPath: "/tmp/sample.pdf")
        let access = ResolvedAccess(fileURL: testURL, securityScopeURL: nil)
        
        XCTAssertEqual(access.fileURL, testURL)
        XCTAssertNil(access.securityScopeURL)
        // stopAccess should be safe to call on non-security-scoped access
        access.stopAccess()
    }

    func testBookmarkErrorDriveDisconnectedDescription() {
        let error = BookmarkError.driveDisconnected
        XCTAssertEqual(error.errorDescription, "The external drive is not connected.")
    }
}

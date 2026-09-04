//
//  AppBuildInfo.swift
//  ComicToPDF
//
//  Created for InkSync Pro.
//  Point-Free Swift 6 & Apple Bundle Architecture.
//

import Foundation
import UIKit

/// Single source of truth for runtime application version, build number, and Git commit SHA.
public struct AppBuildInfo: Sendable {
    
    /// User-facing marketing version (e.g. "1.0.1")
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
    }
    
    /// Monotonically increasing build counter stamped by CI (e.g. "3305")
    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Dev"
    }
    
    /// Git commit short SHA stamped by CI (e.g. "f3d92138")
    public static var commitSHA: String {
        Bundle.main.infoDictionary?["GitCommitSHA"] as? String ?? "local"
    }
    
    /// Formatted short commit SHA for compact display (e.g. "f3d92138" or first 8 chars)
    public static var shortCommitSHA: String {
        let sha = commitSHA
        if sha.count > 8 {
            return String(sha.prefix(8))
        }
        return sha
    }
    
    /// Full badge representation (e.g. "v1.0.1 • Build 3305 (f3d92138)")
    public static var formattedBadge: String {
        "v\(version) • Build \(buildNumber) (\(shortCommitSHA))"
    }
    
    /// Compact badge for pills (e.g. "Build 3305 • f3d92138")
    public static var compactBadge: String {
        "Build \(buildNumber) • \(shortCommitSHA)"
    }
    
    // MARK: - Update Lifecycle Tracking
    
    private static let lastSeenBuildKey = "Inksync_LastSeenBuildNumber_v1"
    
    /// Checks if this is the first launch after installing a new build
    @MainActor
    public static var isNewBuildAfterUpdate: Bool {
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenBuildKey)
        // If never set or different, it is a new build
        guard let lastSeen = lastSeen else { return true }
        return lastSeen != buildNumber && buildNumber != "Dev"
    }
    
    /// Marks the current build as acknowledged by the user
    @MainActor
    public static func markCurrentBuildAsSeen() {
        UserDefaults.standard.set(buildNumber, forKey: lastSeenBuildKey)
    }
}

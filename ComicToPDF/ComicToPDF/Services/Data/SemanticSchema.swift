//
//  SemanticSchema.swift
//  InkSync Pro
//
//  Created by Antigravity on 2026-02-14.
//  Copyright © 2026 InkSync Pro. All rights reserved.
//

import Foundation
import SwiftData
import CoreGraphics

// MARK: - Enterprise Data Schema
// This schema defines the Source of Truth for the InkSync Pro application.
// It uses normalized coordinates (0.0 - 1000.0) for device-agnostic panel rendering.

@Model
final class ComicBook {
    var title: String
    var author: String
    var dateAdded: Date
    var isPrivate: Bool = false
    
    @Relationship(deleteRule: .cascade) 
    var pages: [Page] = []
    
    init(title: String, author: String = "Unknown", isPrivate: Bool = false) {
        self.title = title
        self.author = author
        self.dateAdded = Date()
        self.isPrivate = isPrivate
    }
}

@Model
final class Page {
    var pageNumber: Int
    var imageFileName: String // Link to the file in the local app directory
    var originalSize: CGSize // To handle aspect ratio mapping
    
    @Relationship(deleteRule: .cascade) 
    var panels: [Panel] = []
    
    var comic: ComicBook?
    
    init(pageNumber: Int, imageFileName: String, originalSize: CGSize) {
        self.pageNumber = pageNumber
        self.imageFileName = imageFileName
        self.originalSize = originalSize
    }
}

@Model
final class Panel {
    var id: UUID = UUID()
    var ordinal: Int = 0 
    
    // Normalized Coordinates (0.0 to 1000.0)
    var normalizedX: Float = 0.0
    var normalizedY: Float = 0.0
    var normalizedWidth: Float = 0.0
    var normalizedHeight: Float = 0.0
    
    var isConfirmed: Bool = false
    var page: Page?

    init(ordinal: Int, x: Float, y: Float, w: Float, h: Float, isConfirmed: Bool = false) {
        self.ordinal = ordinal
        self.normalizedX = x
        self.normalizedY = y
        self.normalizedWidth = w
        self.normalizedHeight = h
        self.isConfirmed = isConfirmed
    }
}

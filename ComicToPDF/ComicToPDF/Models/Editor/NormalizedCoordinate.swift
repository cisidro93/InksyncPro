import Foundation
import CoreGraphics

/// A coordinate normalized to a 0-1000 scale.
/// (0,0) is Top-Left, (1000,1000) is Bottom-Right.
struct NormalizedCoordinate: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    
    static let zero = NormalizedCoordinate(x: 0, y: 0)
    static let max = NormalizedCoordinate(x: 1000, y: 1000)
    
    init(x: Double, y: Double) {
        self.x = (x.isNaN || x.isInfinite) ? 0 : min(max(x, 0), 1000)
        self.y = (y.isNaN || y.isInfinite) ? 0 : min(max(y, 0), 1000)
    }
}

/// A rectangle defined in normalized 0-1000 coordinates.
struct NormalizedRect: Codable, Equatable, Hashable {
    var origin: NormalizedCoordinate
    var size: NormalizedSize
    
    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
    var width: Double { size.width }
    var height: Double { size.height }
    
    var center: NormalizedCoordinate {
        NormalizedCoordinate(
            x: origin.x + (size.width / 2.0),
            y: origin.y + (size.height / 2.0)
        )
    }
    
    static let zero = NormalizedRect(origin: .zero, size: .zero)
    static let full = NormalizedRect(origin: .zero, size: NormalizedSize(width: 1000, height: 1000))
    
    init(origin: NormalizedCoordinate, size: NormalizedSize) {
        self.origin = origin
        self.size = size
    }
    
    init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = NormalizedCoordinate(x: x, y: y)
        self.size = NormalizedSize(width: width, height: height)
    }
}

struct NormalizedSize: Codable, Equatable, Hashable {
    var width: Double
    var height: Double
    
    static let zero = NormalizedSize(width: 0, height: 0)
    
    init(width: Double, height: Double) {
        self.width = max(0, min(width, 1000))
        self.height = max(0, min(height, 1000))
    }
}

/// Helper to convert between Normalized Coordinates and View/Image Coordinates
struct CoordinateConverter {
    
    // MARK: - To Normalized (0-1000)
    
    static func normalize(rect: CGRect, in containerSize: CGSize) -> NormalizedRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        
        let x = (rect.origin.x / containerSize.width) * 1000.0
        let y = (rect.origin.y / containerSize.height) * 1000.0
        let w = (rect.width / containerSize.width) * 1000.0
        let h = (rect.height / containerSize.height) * 1000.0
        
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }
    
    static func normalize(point: CGPoint, in containerSize: CGSize) -> NormalizedCoordinate {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        
        let x = (point.x / containerSize.width) * 1000.0
        let y = (point.y / containerSize.height) * 1000.0
        
        return NormalizedCoordinate(x: x, y: y)
    }
    
    // MARK: - From Normalized (0-1000)
    
    static func denormalize(rect: NormalizedRect, in containerSize: CGSize) -> CGRect {
        let x = (rect.origin.x / 1000.0) * containerSize.width
        let y = (rect.origin.y / 1000.0) * containerSize.height
        let w = (rect.size.width / 1000.0) * containerSize.width
        let h = (rect.size.height / 1000.0) * containerSize.height
        
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    static func denormalize(point: NormalizedCoordinate, in containerSize: CGSize) -> CGPoint {
        let x = (point.x / 1000.0) * containerSize.width
        let y = (point.y / 1000.0) * containerSize.height
        return CGPoint(x: x, y: y)
    }
}

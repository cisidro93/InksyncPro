import Foundation
import CoreGraphics

/// A coordinate normalized to a 0-1000 scale.
/// (0,0) is Top-Left, (1000,1000) is Bottom-Right.
struct NormalizedCoordinate: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    
    static let zero = NormalizedCoordinate(x: 0, y: 0)
    static let maximum = NormalizedCoordinate(x: 1000, y: 1000)
    
    init(x: Double, y: Double) {
        self.x = (x.isNaN || x.isInfinite) ? 0 : min(Swift.max(x, 0), 1000)
        self.y = (y.isNaN || y.isInfinite) ? 0 : min(Swift.max(y, 0), 1000)
    }
    
    // Explicit Codable Synthesis guarantees
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try container.decode(Double.self, forKey: .x)
        self.y = try container.decode(Double.self, forKey: .y)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }
    
    enum CodingKeys: String, CodingKey {
        case x, y
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
    
    static func == (lhs: NormalizedCoordinate, rhs: NormalizedCoordinate) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
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
    
    var x: Double {
        get { origin.x }
        set { origin.x = newValue }
    }
    
    var y: Double {
        get { origin.y }
        set { origin.y = newValue }
    }
    
    var width: Double {
        get { size.width }
        set { size.width = newValue }
    }
    
    var height: Double {
        get { size.height }
        set { size.height = newValue }
    }
    
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
    
    // Explicit Codable Synthesis guarantees
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.origin = try container.decode(NormalizedCoordinate.self, forKey: .origin)
        self.size = try container.decode(NormalizedSize.self, forKey: .size)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encode(size, forKey: .size)
    }
    
    enum CodingKeys: String, CodingKey {
        case origin, size
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(origin)
        hasher.combine(size)
    }
    
    static func == (lhs: NormalizedRect, rhs: NormalizedRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
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
    
    // Explicit Codable Synthesis guarantees
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try container.decode(Double.self, forKey: .width)
        self.height = try container.decode(Double.self, forKey: .height)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
    
    enum CodingKeys: String, CodingKey {
        case width, height
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
    }
    
    static func == (lhs: NormalizedSize, rhs: NormalizedSize) -> Bool {
        return lhs.width == rhs.width && lhs.height == rhs.height
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
    
    // ✅ NEW: CGRect Support (Handles Offsets)
    static func normalize(point: CGPoint, in containerRect: CGRect) -> NormalizedCoordinate {
        guard containerRect.width > 0, containerRect.height > 0 else { return .zero }
        
        let x = ((point.x - containerRect.minX) / containerRect.width) * 1000.0
        let y = ((point.y - containerRect.minY) / containerRect.height) * 1000.0
        
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
    
    // ✅ NEW: CGRect Support (Handles Offsets)
    static func denormalize(rect: NormalizedRect, in containerRect: CGRect) -> CGRect {
        let x = containerRect.minX + (rect.origin.x / 1000.0) * containerRect.width
        let y = containerRect.minY + (rect.origin.y / 1000.0) * containerRect.height
        let w = (rect.size.width / 1000.0) * containerRect.width
        let h = (rect.size.height / 1000.0) * containerRect.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    static func denormalize(point: NormalizedCoordinate, in containerRect: CGRect) -> CGPoint {
        let x = containerRect.minX + (point.x / 1000.0) * containerRect.width
        let y = containerRect.minY + (point.y / 1000.0) * containerRect.height
        return CGPoint(x: x, y: y)
    }
}

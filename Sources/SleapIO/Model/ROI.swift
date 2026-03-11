import Foundation
import CoreGraphics
import simd

/// A region of interest defined by geometry.
public struct ROI: Hashable, Codable, Sendable {
    public var annotationType: AnnotationType
    public var name: String
    public var category: String?
    public var score: Float?
    public var source: String?

    /// The geometry as a list of (x, y) coordinates.
    public var points: [SIMD2<Float>]

    public var videoIndex: Int?
    public var frameIndex: Int?
    public var trackIndex: Int?
    public var instanceIndex: Int?

    public init(annotationType: AnnotationType, name: String, points: [SIMD2<Float>]) {
        self.annotationType = annotationType
        self.name = name
        self.points = points
    }

    /// Axis-aligned bounding box enclosing the geometry.
    public var boundingBox: CGRect {
        guard !points.isEmpty else { return .zero }
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                       width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    /// Test whether a point is inside this ROI (polygon point-in-polygon test).
    public func contains(_ point: SIMD2<Float>) -> Bool {
        switch annotationType {
        case .boundingBox:
            let box = boundingBox
            return box.contains(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        case .polygon:
            return _pointInPolygon(point)
        case .point:
            guard let p = points.first else { return false }
            return p.x == point.x && p.y == point.y
        case .ellipse:
            guard points.count >= 2 else { return false }
            let center = points[0]
            let radius = points[1]
            let dx = (point.x - center.x) / (radius.x - center.x)
            let dy = (point.y - center.y) / (radius.y - center.y)
            return dx * dx + dy * dy <= 1.0
        default:
            return false
        }
    }

    private func _pointInPolygon(_ point: SIMD2<Float>) -> Bool {
        let n = points.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let yi = points[i].y, yj = points[j].y
            if (yi > point.y) != (yj > point.y) {
                let xIntersect = points[i].x + (point.y - yi) / (yj - yi) * (points[j].x - points[i].x)
                if point.x < xIntersect {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    // MARK: - Codable for SIMD2<Float>

    enum CodingKeys: String, CodingKey {
        case annotationType, name, category, score, source, points
        case videoIndex, frameIndex, trackIndex, instanceIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        annotationType = try container.decode(AnnotationType.self, forKey: .annotationType)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        score = try container.decodeIfPresent(Float.self, forKey: .score)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        videoIndex = try container.decodeIfPresent(Int.self, forKey: .videoIndex)
        frameIndex = try container.decodeIfPresent(Int.self, forKey: .frameIndex)
        trackIndex = try container.decodeIfPresent(Int.self, forKey: .trackIndex)
        instanceIndex = try container.decodeIfPresent(Int.self, forKey: .instanceIndex)
        let coords = try container.decode([[Float]].self, forKey: .points)
        points = coords.map { SIMD2($0[0], $0.count > 1 ? $0[1] : 0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(annotationType, forKey: .annotationType)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(score, forKey: .score)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(videoIndex, forKey: .videoIndex)
        try container.encodeIfPresent(frameIndex, forKey: .frameIndex)
        try container.encodeIfPresent(trackIndex, forKey: .trackIndex)
        try container.encodeIfPresent(instanceIndex, forKey: .instanceIndex)
        let coords = points.map { [$0.x, $0.y] }
        try container.encode(coords, forKey: .points)
    }
}

import Foundation
import CoreGraphics

/// A single pose instance (set of landmark points) within a frame.
public class Instance: Hashable, @unchecked Sendable {
    /// The landmark points for this instance.
    public var points: PointsArray

    /// The skeleton defining the landmark topology.
    public let skeleton: Skeleton

    /// The track this instance belongs to, if any.
    public var track: Track?

    /// Tracking confidence score (from tracker, not pose model).
    public var trackingScore: Float?

    /// If this instance was created from a predicted instance, reference to it.
    public weak var fromPredicted: PredictedInstance?

    public init(skeleton: Skeleton,
                points: PointsArray? = nil,
                track: Track? = nil,
                trackingScore: Float? = nil,
                fromPredicted: PredictedInstance? = nil) {
        self.skeleton = skeleton
        var pts = points ?? PointsArray(count: skeleton.nodes.count)
        pts.skeleton = skeleton
        self.points = pts
        self.track = track
        self.trackingScore = trackingScore
        self.fromPredicted = fromPredicted
    }

    // MARK: - Point access by node

    public subscript(node: Node) -> Point {
        get { points[node] }
        set { points[node] = newValue }
    }

    public subscript(name: String) -> Point {
        get { points[name] }
        set { points[name] = newValue }
    }

    // MARK: - Geometry

    /// Axis-aligned bounding box of visible points.
    public var boundingBox: CGRect? {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var hasVisible = false

        for i in 0..<points.count {
            guard points.visibility[i] else { continue }
            let x = points.coordinates[i * 2]
            let y = points.coordinates[i * 2 + 1]
            guard !x.isNaN && !y.isNaN else { continue }
            hasVisible = true
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        guard hasVisible else { return nil }
        return CGRect(
            x: CGFloat(minX), y: CGFloat(minY),
            width: CGFloat(maxX - minX), height: CGFloat(maxY - minY)
        )
    }

    /// Whether this instance's visible points overlap with another's bounding box.
    public func overlaps(with other: Instance) -> Bool {
        guard let selfBox = boundingBox, let otherBox = other.boundingBox else {
            return false
        }
        return selfBox.intersects(otherBox)
    }

    // MARK: - Identity equality

    public static func == (lhs: Instance, rhs: Instance) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

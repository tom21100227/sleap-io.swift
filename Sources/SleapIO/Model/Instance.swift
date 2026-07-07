import Foundation
import CoreGraphics

/// A single pose instance (set of landmark points) within a frame.
public class Instance: Hashable, @unchecked Sendable {
    /// The landmark points for this instance.
    public var points: PointsArray

    /// The skeleton defining the landmark topology.
    ///
    /// Mutate only via `replaceSkeleton` so `points.skeleton` stays in sync.
    public internal(set) var skeleton: Skeleton

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
    ///
    /// This is a coarse boolean intersection test. For the true
    /// Intersection-over-Union metric used by matching, prefer
    /// ``boundingBoxIoU(with:)`` / ``overlapsWith(_:iouThreshold:)``.
    public func overlaps(with other: Instance) -> Bool {
        guard let selfBox = boundingBox, let otherBox = other.boundingBox else {
            return false
        }
        return selfBox.intersects(otherBox)
    }

    /// Intersection-over-Union of the two instances' visible-point bounding boxes.
    ///
    /// Returns a value in `[0, 1]`: `1.0` for identical bounding boxes, `0.0` when
    /// either instance has no visible points, when the boxes do not truly overlap
    /// (touching edges count as no overlap), or when the union area is zero.
    ///
    /// Mirrors the IoU computation in Python `Instance.overlaps_with`.
    ///
    /// - Parameter other: The instance to compare against.
    /// - Returns: The bounding-box IoU in `[0, 1]`.
    public func boundingBoxIoU(with other: Instance) -> Float {
        guard let a = boundingBoxArray(), let b = other.boundingBoxArray() else {
            return 0
        }
        // Intersection rectangle.
        let interMinX = Swift.max(a[0][0], b[0][0])
        let interMinY = Swift.max(a[0][1], b[0][1])
        let interMaxX = Swift.min(a[1][0], b[1][0])
        let interMaxY = Swift.min(a[1][1], b[1][1])

        // No overlap if either dimension has non-positive extent.
        guard interMinX < interMaxX, interMinY < interMaxY else { return 0 }

        let intersection = (interMaxX - interMinX) * (interMaxY - interMinY)
        let areaA = (a[1][0] - a[0][0]) * (a[1][1] - a[0][1])
        let areaB = (b[1][0] - b[0][0]) * (b[1][1] - b[0][1])
        let union = areaA + areaB - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Whether this instance overlaps another by bounding-box IoU at or above a
    /// threshold.
    ///
    /// Overlap is computed from the bounding boxes of the visible points via
    /// ``boundingBoxIoU(with:)``. If either instance has no visible points, they
    /// do not overlap. Mirrors Python `Instance.overlaps_with`.
    ///
    /// - Parameters:
    ///   - other: The instance to compare against.
    ///   - iouThreshold: Minimum IoU value to consider the instances overlapping.
    ///     Defaults to `0.5`.
    /// - Returns: `true` if the bounding-box IoU is `>= iouThreshold`.
    public func overlapsWith(_ other: Instance, iouThreshold: Float = 0.5) -> Bool {
        boundingBoxIoU(with: other) >= iouThreshold
    }

    // MARK: - Pose / identity correspondence

    /// Whether this instance has the same pose as another instance.
    ///
    /// The instances must first share a compatible skeleton (same set of node
    /// names, per ``Skeleton/matches(_:requireSameOrder:)``); poses are then
    /// compared positionally by node index.
    ///
    /// - When `tolerance` is `nil` (the default), coordinates must match exactly,
    ///   with invisible points treated as `NaN`: the two instances must share the
    ///   same visibility (`NaN`) pattern and every visible coordinate must be
    ///   bit-for-bit equal.
    /// - When `tolerance` is provided, the visibility (`NaN`) patterns must still
    ///   match exactly, and every mutually-visible point must lie within
    ///   `tolerance` Euclidean distance. Two instances with no visible points are
    ///   considered equal.
    ///
    /// Mirrors Python `Instance.same_pose_as`.
    ///
    /// - Parameters:
    ///   - other: The instance to compare against.
    ///   - tolerance: Maximum per-point distance (in pixels) for a match, or `nil`
    ///     for exact comparison.
    /// - Returns: `true` if the poses are the same within the given tolerance.
    public func samePoseAs(_ other: Instance, tolerance: Float? = nil) -> Bool {
        guard skeleton.matches(other.skeleton) else { return false }

        let a = numpy(invisibleAsNaN: true)
        let b = other.numpy(invisibleAsNaN: true)
        guard a.count == b.count else { return false }

        if let tolerance {
            for i in 0..<a.count {
                let aNaN = a[i][0].isNaN || a[i][1].isNaN
                let bNaN = b[i][0].isNaN || b[i][1].isNaN
                // Visibility (NaN) patterns must match exactly.
                if aNaN != bNaN { return false }
                if aNaN { continue }
                let dx = a[i][0] - b[i][0]
                let dy = a[i][1] - b[i][1]
                if (dx * dx + dy * dy).squareRoot() > tolerance { return false }
            }
            // No mismatches (also covers the all-invisible case).
            return true
        } else {
            // Exact comparison with NaN treated as equal (equal_nan semantics).
            for i in 0..<a.count {
                for j in 0..<2 {
                    let av = a[i][j], bv = b[i][j]
                    if av.isNaN || bv.isNaN {
                        if av.isNaN != bv.isNaN { return false }
                    } else if av != bv {
                        return false
                    }
                }
            }
            return true
        }
    }

    /// Whether this instance shares the same track identity as another.
    ///
    /// Instances have the same identity only when both carry the *same* ``Track``
    /// object (compared by identity, not by name). If either instance has no
    /// track, they are not considered to share an identity. Mirrors Python
    /// `Instance.same_identity_as`.
    ///
    /// - Parameter other: The instance to compare against.
    /// - Returns: `true` if both instances reference the same track object.
    public func sameIdentityAs(_ other: Instance) -> Bool {
        guard let selfTrack = track, let otherTrack = other.track else { return false }
        return selfTrack === otherTrack
    }

    // MARK: - Identity equality

    public static func == (lhs: Instance, rhs: Instance) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

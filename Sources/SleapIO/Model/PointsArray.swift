import Foundation
import simd

/// Contiguous storage for N points belonging to one instance.
///
/// Backed by contiguous Float32 buffers for GPU/Accelerate compatibility.
/// Subscriptable by integer index or by `Node` (when a skeleton is associated).
public struct PointsArray: Sendable {
    /// Interleaved xy coordinates as [x0, y0, x1, y1, ...]. Length = count * 2.
    public var coordinates: ContiguousArray<Float>

    /// Per-point visibility. Length = count.
    public var visibility: ContiguousArray<Bool>

    /// Per-point completeness. Length = count.
    public var completeness: ContiguousArray<Bool>

    /// Skeleton for node-based subscript access. Not part of value semantics.
    public var skeleton: Skeleton?

    /// Number of points.
    public var count: Int { visibility.count }

    // MARK: - Init

    public init(count: Int) {
        self.coordinates = ContiguousArray(repeating: Float.nan, count: count * 2)
        self.visibility = ContiguousArray(repeating: false, count: count)
        self.completeness = ContiguousArray(repeating: false, count: count)
    }

    public init(points: [Point]) {
        let n = points.count
        var coords = ContiguousArray<Float>(repeating: 0, count: n * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: n)
        var comp = ContiguousArray<Bool>(repeating: false, count: n)
        for i in 0..<n {
            coords[i * 2] = points[i].x
            coords[i * 2 + 1] = points[i].y
            vis[i] = points[i].visible
            comp[i] = points[i].complete
        }
        self.coordinates = coords
        self.visibility = vis
        self.completeness = comp
    }

    /// Create from raw coordinate data (used by the SLP reader during materialization).
    public init(coordinates: ContiguousArray<Float>,
                visibility: ContiguousArray<Bool>,
                completeness: ContiguousArray<Bool>) {
        precondition(coordinates.count == visibility.count * 2)
        precondition(visibility.count == completeness.count)
        self.coordinates = coordinates
        self.visibility = visibility
        self.completeness = completeness
    }

    // MARK: - Subscript by index

    public subscript(index: Int) -> Point {
        get {
            precondition(index >= 0 && index < count)
            return Point(
                x: coordinates[index * 2],
                y: coordinates[index * 2 + 1],
                visible: visibility[index],
                complete: completeness[index]
            )
        }
        set {
            precondition(index >= 0 && index < count)
            coordinates[index * 2] = newValue.x
            coordinates[index * 2 + 1] = newValue.y
            visibility[index] = newValue.visible
            completeness[index] = newValue.complete
        }
    }

    // MARK: - Subscript by Node

    public subscript(node: Node) -> Point {
        get {
            guard let skel = skeleton, let idx = skel.index(of: node) else {
                preconditionFailure("Node '\(node.name)' not found in skeleton")
            }
            return self[idx]
        }
        set {
            guard let skel = skeleton, let idx = skel.index(of: node) else {
                preconditionFailure("Node '\(node.name)' not found in skeleton")
            }
            self[idx] = newValue
        }
    }

    // MARK: - Subscript by name

    public subscript(name: String) -> Point {
        get {
            guard let skel = skeleton, let node = skel.node(named: name),
                  let idx = skel.index(of: node) else {
                preconditionFailure("Node named '\(name)' not found in skeleton")
            }
            return self[idx]
        }
        set {
            guard let skel = skeleton, let node = skel.node(named: name),
                  let idx = skel.index(of: node) else {
                preconditionFailure("Node named '\(name)' not found in skeleton")
            }
            self[idx] = newValue
        }
    }

    // MARK: - Bulk SIMD access

    /// All xy as SIMD2 array.
    public var simdCoordinates: [SIMD2<Float>] {
        (0..<count).map { i in
            SIMD2(coordinates[i * 2], coordinates[i * 2 + 1])
        }
    }
}

/// Extends PointsArray with per-point confidence scores.
public struct PredictedPointsArray: Sendable {
    public var points: PointsArray
    public var scores: ContiguousArray<Float>

    public var count: Int { points.count }

    public var skeleton: Skeleton? {
        get { points.skeleton }
        set { points.skeleton = newValue }
    }

    public init(count: Int) {
        self.points = PointsArray(count: count)
        self.scores = ContiguousArray(repeating: 0, count: count)
    }

    public init(points: [PredictedPoint]) {
        self.points = PointsArray(points: points.map(\.point))
        self.scores = ContiguousArray(points.map(\.score))
    }

    public init(pointsArray: PointsArray, scores: ContiguousArray<Float>) {
        precondition(pointsArray.count == scores.count)
        self.points = pointsArray
        self.scores = scores
    }

    public subscript(index: Int) -> PredictedPoint {
        get {
            PredictedPoint(point: points[index], score: scores[index])
        }
        set {
            points[index] = newValue.point
            scores[index] = newValue.score
        }
    }

    public subscript(node: Node) -> PredictedPoint {
        get {
            guard let skel = points.skeleton, let idx = skel.index(of: node) else {
                preconditionFailure("Node '\(node.name)' not found in skeleton")
            }
            return self[idx]
        }
        set {
            guard let skel = points.skeleton, let idx = skel.index(of: node) else {
                preconditionFailure("Node '\(node.name)' not found in skeleton")
            }
            self[idx] = newValue
        }
    }

    public subscript(name: String) -> PredictedPoint {
        get {
            guard let skel = points.skeleton, let node = skel.node(named: name),
                  let idx = skel.index(of: node) else {
                preconditionFailure("Node named '\(name)' not found in skeleton")
            }
            return self[idx]
        }
        set {
            guard let skel = points.skeleton, let node = skel.node(named: name),
                  let idx = skel.index(of: node) else {
                preconditionFailure("Node named '\(name)' not found in skeleton")
            }
            self[idx] = newValue
        }
    }
}

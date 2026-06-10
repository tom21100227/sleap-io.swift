import Foundation
import simd

// E2.1 / E2.2: numpy-style array export and derived geometry on
// Instance / PredictedInstance / LabeledFrame, mirroring Python `sleap_io`.
// All accessors are additive and return copies.

extension Instance {

    /// Points as an `(nNodes, 2)` array of `[x, y]` rows.
    ///
    /// - Parameter invisibleAsNaN: When `true` (default), points that are not visible
    ///   are emitted as `[NaN, NaN]`; when `false`, the stored coordinates are returned
    ///   regardless of visibility.
    ///
    /// Mirrors `Instance.numpy(invisible_as_nan=)`.
    public func numpy(invisibleAsNaN: Bool = true) -> [[Float]] {
        var rows = [[Float]]()
        rows.reserveCapacity(points.count)
        for i in 0..<points.count {
            if invisibleAsNaN && !points.visibility[i] {
                rows.append([.nan, .nan])
            } else {
                rows.append([points.coordinates[i * 2], points.coordinates[i * 2 + 1]])
            }
        }
        return rows
    }

    /// Number of visible points. Mirrors `Instance.n_visible`.
    public var nVisible: Int {
        var n = 0
        for v in points.visibility where v { n += 1 }
        return n
    }

    /// Whether no points are visible. Mirrors `Instance.is_empty`.
    public var isEmpty: Bool {
        !points.visibility.contains(true)
    }

    /// Mean `(x, y)` of visible, finite points, or `nil` if there are none.
    /// Mirrors `Instance.centroid_xy`.
    public var centroidXY: SIMD2<Float>? {
        var sumX: Float = 0, sumY: Float = 0
        var n = 0
        for i in 0..<points.count where points.visibility[i] {
            let x = points.coordinates[i * 2], y = points.coordinates[i * 2 + 1]
            guard x.isFinite, y.isFinite else { continue }
            sumX += x; sumY += y; n += 1
        }
        guard n > 0 else { return nil }
        return SIMD2(sumX / Float(n), sumY / Float(n))
    }

    /// Bounding box of visible points as `[[minX, minY], [maxX, maxY]]`, or `nil`
    /// if there are no visible points. Mirrors `Instance.bounding_box`.
    ///
    /// (The existing ``boundingBox`` property returns the same extent as a `CGRect`.)
    public func boundingBoxArray() -> [[Float]]? {
        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var any = false
        for i in 0..<points.count where points.visibility[i] {
            let x = points.coordinates[i * 2], y = points.coordinates[i * 2 + 1]
            guard x.isFinite, y.isFinite else { continue }
            any = true
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
        guard any else { return nil }
        return [[minX, minY], [maxX, maxY]]
    }
}

extension PredictedInstance {

    /// Points as `(nNodes, 2)` rows, or `(nNodes, 3)` with a per-point score column
    /// when `scores` is `true`. The score column is never replaced with `NaN`.
    ///
    /// Mirrors `PredictedInstance.numpy(invisible_as_nan=, scores=)`.
    public func numpy(invisibleAsNaN: Bool = true, scores: Bool) -> [[Float]] {
        let xy = numpy(invisibleAsNaN: invisibleAsNaN) // Instance.numpy(invisibleAsNaN:)
        guard scores else { return xy }
        var rows = [[Float]]()
        rows.reserveCapacity(xy.count)
        for i in 0..<xy.count {
            rows.append([xy[i][0], xy[i][1], predictedPoints.scores[i]])
        }
        return rows
    }
}

extension LabeledFrame {

    /// All instances as an `(nInstances, nNodes, 2)` array, with invisible points as
    /// `NaN`. `nNodes` is taken from the first instance. Mirrors `LabeledFrame.numpy`.
    ///
    /// Note: instance order is whatever ``instances`` holds.
    public func numpy() -> [[[Float]]] {
        instances.map { $0.numpy(invisibleAsNaN: true) }
    }
}

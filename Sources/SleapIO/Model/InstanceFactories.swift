import Foundation

// E2.3: Convenience factories for building Instance / PredictedInstance from
// scratch or from numpy-style `(nNodes, 2)` / `(nNodes, 3)` arrays. Mirrors
// Python `Instance.empty` / `Instance.from_numpy` and
// `PredictedInstance.empty(score=)` / `PredictedInstance.from_numpy`.
//
// These round-trip with the `numpy(...)` accessors: a row whose `x` or `y` is
// non-finite (e.g. `NaN`) becomes an invisible point, which `numpy(invisibleAsNaN:)`
// re-emits as `[NaN, NaN]`.

extension Instance {

    /// An instance with one invisible point per skeleton node.
    ///
    /// All coordinates are `NaN` and every point is marked not-visible, so
    /// ``isEmpty`` is `true` and ``nVisible`` is `0`. Mirrors `Instance.empty`.
    public static func empty(skeleton: Skeleton, track: Track? = nil) -> Instance {
        var pts = PointsArray(count: skeleton.nodes.count)
        pts.skeleton = skeleton
        return Instance(skeleton: skeleton, points: pts, track: track)
    }

    /// Build an instance from an `(nNodes, 2)` array of `[x, y]` rows.
    ///
    /// A row whose `x` or `y` is non-finite (e.g. `[NaN, NaN]`) yields an invisible
    /// point; a finite row yields a visible point at `(x, y)`. The number of rows
    /// should match `skeleton.nodes.count`. Mirrors `Instance.from_numpy`.
    public static func from(numpy points: [[Float]],
                            skeleton: Skeleton,
                            track: Track? = nil) -> Instance {
        var pts = PointsArray(count: skeleton.nodes.count)
        pts.skeleton = skeleton
        applyXY(points, to: &pts)
        return Instance(skeleton: skeleton, points: pts, track: track)
    }
}

extension PredictedInstance {

    /// A predicted instance with one invisible, zero-score point per skeleton node.
    ///
    /// Mirrors `PredictedInstance.empty(score=)`.
    public static func empty(skeleton: Skeleton,
                             score: Float = 0,
                             track: Track? = nil) -> PredictedInstance {
        var pts = PredictedPointsArray(count: skeleton.nodes.count)
        pts.skeleton = skeleton
        return PredictedInstance(skeleton: skeleton, points: pts, score: score, track: track)
    }

    /// Build a predicted instance from an `(nNodes, 2)` or `(nNodes, 3)` array.
    ///
    /// Each row is `[x, y]` or `[x, y, pointScore]`. A row whose `x` or `y` is
    /// non-finite yields an invisible point. Per-point scores come from `pointScores`
    /// when provided, otherwise from a third column when present, otherwise `0`.
    /// Mirrors `PredictedInstance.from_numpy`.
    public static func from(numpy points: [[Float]],
                            skeleton: Skeleton,
                            score: Float = 0,
                            pointScores: [Float]? = nil,
                            track: Track? = nil) -> PredictedInstance {
        var xy = PointsArray(count: skeleton.nodes.count)
        applyXY(points, to: &xy)

        var scores = ContiguousArray<Float>(repeating: 0, count: skeleton.nodes.count)
        let n = Swift.min(points.count, scores.count)
        if let pointScores {
            for i in 0..<Swift.min(pointScores.count, scores.count) {
                scores[i] = pointScores[i]
            }
        } else {
            for i in 0..<n where points[i].count >= 3 {
                scores[i] = points[i][2]
            }
        }

        var pts = PredictedPointsArray(pointsArray: xy, scores: scores)
        pts.skeleton = skeleton
        return PredictedInstance(skeleton: skeleton, points: pts, score: score, track: track)
    }
}

private extension Instance {

    /// Fill `xy` from `(nNodes, 2+)` rows: finite `(x, y)` => visible point,
    /// non-finite row => invisible point.
    static func applyXY(_ points: [[Float]], to xy: inout PointsArray) {
        let n = Swift.min(points.count, xy.count)
        for i in 0..<n {
            let row = points[i]
            guard row.count >= 2 else { continue }
            let x = row[0], y = row[1]
            if x.isFinite && y.isFinite {
                xy[i] = Point(x: x, y: y, visible: true, complete: false)
            } else {
                xy[i] = Point(x: x, y: y, visible: false, complete: false)
            }
        }
    }
}

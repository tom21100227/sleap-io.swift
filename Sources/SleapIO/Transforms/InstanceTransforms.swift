import CoreGraphics

extension Instance {
    /// Return a new instance with all points translated by (dx, dy).
    public func translated(by offset: SIMD2<Float>) -> Instance {
        transformed(by: AffineTransform2D.translation(dx: offset.x, dy: offset.y))
    }

    /// Return a new instance with all points scaled relative to an origin.
    public func scaled(by factor: SIMD2<Float>, origin: SIMD2<Float> = .zero) -> Instance {
        transformed(by: AffineTransform2D.scale(sx: factor.x, sy: factor.y, origin: origin))
    }

    /// Return a new instance with all points rotated around an origin.
    public func rotated(by radians: Float, around origin: SIMD2<Float> = .zero) -> Instance {
        transformed(by: AffineTransform2D.rotation(radians: radians, around: origin))
    }

    /// Return a new instance cropped to a bounding box.
    /// Points outside the box are marked invisible; coordinates are unchanged.
    public func cropped(to rect: CGRect) -> Instance {
        var newPoints = points
        newPoints.skeleton = skeleton
        let minX = Float(rect.minX)
        let minY = Float(rect.minY)
        let maxX = Float(rect.maxX)
        let maxY = Float(rect.maxY)

        for i in 0..<newPoints.count {
            let x = newPoints.coordinates[i * 2]
            let y = newPoints.coordinates[i * 2 + 1]
            if x < minX || x > maxX || y < minY || y > maxY || x.isNaN || y.isNaN {
                newPoints.visibility[i] = false
            }
        }

        return _cloneWithPoints(newPoints)
    }

    /// Apply an arbitrary 3x3 affine transform matrix (row-major) and return a new instance.
    public func transformed(by matrix: [Float]) -> Instance {
        var newPoints = points
        newPoints.skeleton = skeleton
        newPoints.apply(transform: matrix)
        return _cloneWithPoints(newPoints)
    }

    /// Create a new Instance (or PredictedInstance) preserving subclass identity and metadata.
    private func _cloneWithPoints(_ newPoints: PointsArray) -> Instance {
        if let pred = self as? PredictedInstance {
            var newPredPoints = pred.predictedPoints
            newPredPoints.points = newPoints
            let result = PredictedInstance(skeleton: skeleton, points: newPredPoints, score: pred.score, track: track, trackingScore: trackingScore)
            result.fromPredicted = fromPredicted
            return result
        }
        let result = Instance(skeleton: skeleton, points: newPoints, track: track, trackingScore: trackingScore)
        result.fromPredicted = fromPredicted
        return result
    }
}

import Foundation

/// A pose instance produced by a prediction model, with a confidence score.
public final class PredictedInstance: Instance, @unchecked Sendable {
    /// Model confidence score for this instance.
    public var score: Float

    /// Per-point predicted points with scores.
    public var predictedPoints: PredictedPointsArray

    public init(skeleton: Skeleton,
                points: PredictedPointsArray,
                score: Float,
                track: Track? = nil,
                trackingScore: Float? = nil) {
        self.score = score
        self.predictedPoints = points
        super.init(skeleton: skeleton,
                   points: points.points,
                   track: track,
                   trackingScore: trackingScore)
    }

    /// Override points setter to keep predictedPoints in sync.
    public override var points: PointsArray {
        get { predictedPoints.points }
        set { predictedPoints.points = newValue }
    }
}

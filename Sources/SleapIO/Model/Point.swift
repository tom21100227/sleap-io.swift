import Foundation
import simd

/// A single 2D point. Value type used for individual point access.
public struct Point: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var visible: Bool
    public var complete: Bool

    public init(x: Float, y: Float, visible: Bool = true, complete: Bool = false) {
        self.x = x
        self.y = y
        self.visible = visible
        self.complete = complete
    }

    /// SIMD representation for math operations.
    public var simd: SIMD2<Float> {
        get { SIMD2(x, y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }
}

/// A single predicted point with a confidence score.
public struct PredictedPoint: Hashable, Codable, Sendable {
    public var point: Point
    public var score: Float

    public var x: Float {
        get { point.x }
        set { point.x = newValue }
    }

    public var y: Float {
        get { point.y }
        set { point.y = newValue }
    }

    public var visible: Bool {
        get { point.visible }
        set { point.visible = newValue }
    }

    public var complete: Bool {
        get { point.complete }
        set { point.complete = newValue }
    }

    public init(x: Float, y: Float, visible: Bool = true, complete: Bool = false, score: Float = 0.0) {
        self.point = Point(x: x, y: y, visible: visible, complete: complete)
        self.score = score
    }

    public init(point: Point, score: Float = 0.0) {
        self.point = point
        self.score = score
    }
}

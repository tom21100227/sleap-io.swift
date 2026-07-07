import Foundation
import simd

/// A bounding box annotation.
///
/// Supports axis-aligned and oriented (rotated) bounding boxes with optional
/// metadata for associating with videos, frames, tracks, and instances. Bounding
/// boxes are first-class annotations for object detection and tracking workflows.
///
/// Mirrors Python sleap-io's `sleap_io.model.bbox` hierarchy
/// (`BoundingBox` / `UserBoundingBox` / `PredictedBoundingBox`). Rather than a
/// class hierarchy, this is modeled as a single value type carrying an
/// ``isPredicted`` flag and an optional ``score``, consistent with the existing
/// annotation value types (``ROI``, ``SegmentationMask``). Use ``user(x_center:y_center:width:height:angle:)``
/// and ``predicted(x_center:y_center:width:height:angle:score:)`` (or the
/// ``from(x1:y1:x2:y2:)`` / ``from(x:y:width:height:)`` corner/xywh factories) to
/// construct instances.
///
/// Persisted to the `/bboxes` compound dataset of an SLP file (format 1.7+).
public struct BoundingBox: Hashable, Codable, Sendable {

    /// Center x-coordinate in pixels.
    public var xCenter: Double
    /// Center y-coordinate in pixels.
    public var yCenter: Double
    /// Box width in pixels.
    public var width: Double
    /// Box height in pixels.
    public var height: Double
    /// Rotation angle in radians (`0` = axis-aligned).
    public var angle: Double

    /// Whether this bounding box is a model prediction (as opposed to
    /// human-annotated). Mirrors the `UserBoundingBox` / `PredictedBoundingBox`
    /// distinction in Python.
    public var isPredicted: Bool
    /// Confidence score, present only for predicted boxes.
    public var score: Float?

    /// Index of the associated video in the parent ``Labels/videos`` table, or `nil`.
    public var videoIndex: Int?
    /// Frame index within the video, or `nil`.
    public var frameIndex: Int?
    /// Index of the associated track in the parent ``Labels/tracks`` table, or `nil`.
    public var trackIndex: Int?
    /// Index of the associated pose instance within its frame, or `nil`.
    public var instanceIndex: Int?

    /// Class label (e.g. `"mouse"`, `"fly"`).
    public var category: String?
    /// Human-readable name.
    public var name: String?
    /// Annotation source identifier.
    public var source: String?

    /// Designated initializer. Prefer the ``user`` / ``predicted`` /
    /// ``from(x1:y1:x2:y2:)`` / ``from(x:y:width:height:)`` factories in
    /// application code.
    public init(
        xCenter: Double,
        yCenter: Double,
        width: Double,
        height: Double,
        angle: Double = 0.0,
        isPredicted: Bool = false,
        score: Float? = nil,
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        trackIndex: Int? = nil,
        instanceIndex: Int? = nil,
        category: String? = nil,
        name: String? = nil,
        source: String? = nil
    ) {
        self.xCenter = xCenter
        self.yCenter = yCenter
        self.width = width
        self.height = height
        self.angle = angle
        self.isPredicted = isPredicted
        self.score = score
        self.videoIndex = videoIndex
        self.frameIndex = frameIndex
        self.trackIndex = trackIndex
        self.instanceIndex = instanceIndex
        self.category = category
        self.name = name
        self.source = source
    }

    // MARK: - Factories

    /// Create a human-annotated bounding box from its center, size, and angle.
    public static func user(
        xCenter: Double,
        yCenter: Double,
        width: Double,
        height: Double,
        angle: Double = 0.0,
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        trackIndex: Int? = nil,
        instanceIndex: Int? = nil,
        category: String? = nil,
        name: String? = nil,
        source: String? = nil
    ) -> BoundingBox {
        BoundingBox(
            xCenter: xCenter, yCenter: yCenter, width: width, height: height, angle: angle,
            isPredicted: false, score: nil,
            videoIndex: videoIndex, frameIndex: frameIndex, trackIndex: trackIndex,
            instanceIndex: instanceIndex, category: category, name: name, source: source)
    }

    /// Create a model-predicted bounding box with a confidence score.
    public static func predicted(
        xCenter: Double,
        yCenter: Double,
        width: Double,
        height: Double,
        angle: Double = 0.0,
        score: Float,
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        trackIndex: Int? = nil,
        instanceIndex: Int? = nil,
        category: String? = nil,
        name: String? = nil,
        source: String? = nil
    ) -> BoundingBox {
        BoundingBox(
            xCenter: xCenter, yCenter: yCenter, width: width, height: height, angle: angle,
            isPredicted: true, score: score,
            videoIndex: videoIndex, frameIndex: frameIndex, trackIndex: trackIndex,
            instanceIndex: instanceIndex, category: category, name: name, source: source)
    }

    /// Create an axis-aligned bounding box from corner coordinates.
    ///
    /// - Parameters:
    ///   - x1: Left edge x-coordinate.
    ///   - y1: Top edge y-coordinate.
    ///   - x2: Right edge x-coordinate (must be `>= x1`).
    ///   - y2: Bottom edge y-coordinate (must be `>= y1`).
    ///   - isPredicted: Whether this is a prediction. Defaults to `false`.
    ///   - score: Optional confidence score.
    /// - Returns: A new bounding box, or `nil` if `x2 < x1` or `y2 < y1`.
    public static func from(
        x1: Double, y1: Double, x2: Double, y2: Double,
        isPredicted: Bool = false, score: Float? = nil
    ) -> BoundingBox? {
        guard x2 >= x1, y2 >= y1 else { return nil }
        let w = x2 - x1
        let h = y2 - y1
        return BoundingBox(
            xCenter: x1 + w / 2, yCenter: y1 + h / 2, width: w, height: h,
            isPredicted: isPredicted, score: score)
    }

    /// Create an axis-aligned bounding box from a top-left corner and dimensions.
    public static func from(
        x: Double, y: Double, width w: Double, height h: Double,
        isPredicted: Bool = false, score: Float? = nil
    ) -> BoundingBox {
        BoundingBox(
            xCenter: x + w / 2, yCenter: y + h / 2, width: w, height: h,
            isPredicted: isPredicted, score: score)
    }

    // MARK: - Geometry

    /// Whether this bounding box is rotated (non-axis-aligned).
    public var isRotated: Bool { abs(angle) > 1e-10 }

    /// Area of the bounding box.
    public var area: Double { width * height }

    /// Corner coordinates as `(x1, y1, x2, y2)` for an axis-aligned box.
    ///
    /// Returns `nil` for rotated boxes, where corner ordering is ambiguous — use
    /// ``bounds`` or ``corners`` instead.
    public var xyxy: (x1: Double, y1: Double, x2: Double, y2: Double)? {
        guard !isRotated else { return nil }
        let halfW = width / 2
        let halfH = height / 2
        return (xCenter - halfW, yCenter - halfH, xCenter + halfW, yCenter + halfH)
    }

    /// Top-left corner and dimensions as `(x, y, width, height)` for an
    /// axis-aligned box. Returns `nil` for rotated boxes.
    public var xywh: (x: Double, y: Double, width: Double, height: Double)? {
        guard !isRotated else { return nil }
        return (xCenter - width / 2, yCenter - height / 2, width, height)
    }

    /// The four corner points (top-left, top-right, bottom-right, bottom-left,
    /// before rotation), rotated about the center for oriented boxes.
    public var corners: [SIMD2<Double>] {
        let halfW = width / 2
        let halfH = height / 2
        var pts: [SIMD2<Double>] = [
            SIMD2(-halfW, -halfH),
            SIMD2(halfW, -halfH),
            SIMD2(halfW, halfH),
            SIMD2(-halfW, halfH),
        ]
        if isRotated {
            let c = cos(angle)
            let s = sin(angle)
            pts = pts.map { p in
                SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
            }
        }
        return pts.map { SIMD2($0.x + xCenter, $0.y + yCenter) }
    }

    /// Axis-aligned bounding extent as `(minX, minY, maxX, maxY)`. Defined for
    /// both axis-aligned and rotated boxes.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        if !isRotated {
            let halfW = width / 2
            let halfH = height / 2
            return (xCenter - halfW, yCenter - halfH, xCenter + halfW, yCenter + halfH)
        }
        let c = corners
        let xs = c.map { $0.x }
        let ys = c.map { $0.y }
        return (xs.min() ?? xCenter, ys.min() ?? yCenter, xs.max() ?? xCenter, ys.max() ?? yCenter)
    }
}

import Foundation

/// A centroid (single-point) annotation.
///
/// Centroids mark the center location of an object, used by detection and
/// tracking workflows (and interchange formats such as TrackMate). A centroid
/// carries an `(x, y)` location plus optional metadata associating it with a
/// video, frame, track, and pose instance.
///
/// Mirrors the intended `UserCentroid` / `PredictedCentroid` hierarchy: rather
/// than subclasses, this is a single value type carrying an ``isPredicted`` flag
/// and an optional ``score``, consistent with ``BoundingBox``, ``ROI``, and
/// ``SegmentationMask``. Use ``user(x:y:)`` and ``predicted(x:y:score:)`` to
/// construct instances.
///
/// - Note: Upstream Python sleap-io does not (yet) ship a centroid dataset or
///   model. This type and its `/centroids` compound schema are a Swift-side
///   design following the `/bboxes` layout, and round-trip through SLP save/load.
///
/// Persisted to the `/centroids` compound dataset of an SLP file.
public struct Centroid: Hashable, Codable, Sendable {

    /// x-coordinate in pixels.
    public var x: Double
    /// y-coordinate in pixels.
    public var y: Double

    /// Whether this centroid is a model prediction (as opposed to
    /// human-annotated).
    public var isPredicted: Bool
    /// Confidence score, present only for predicted centroids.
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

    /// Designated initializer. Prefer the ``user(x:y:)`` / ``predicted(x:y:score:)``
    /// factories in application code.
    public init(
        x: Double,
        y: Double,
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
        self.x = x
        self.y = y
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

    /// Create a human-annotated centroid.
    public static func user(
        x: Double,
        y: Double,
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        trackIndex: Int? = nil,
        instanceIndex: Int? = nil,
        category: String? = nil,
        name: String? = nil,
        source: String? = nil
    ) -> Centroid {
        Centroid(
            x: x, y: y, isPredicted: false, score: nil,
            videoIndex: videoIndex, frameIndex: frameIndex, trackIndex: trackIndex,
            instanceIndex: instanceIndex, category: category, name: name, source: source)
    }

    /// Create a model-predicted centroid with a confidence score.
    public static func predicted(
        x: Double,
        y: Double,
        score: Float,
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        trackIndex: Int? = nil,
        instanceIndex: Int? = nil,
        category: String? = nil,
        name: String? = nil,
        source: String? = nil
    ) -> Centroid {
        Centroid(
            x: x, y: y, isPredicted: true, score: score,
            videoIndex: videoIndex, frameIndex: frameIndex, trackIndex: trackIndex,
            instanceIndex: instanceIndex, category: category, name: name, source: source)
    }
}

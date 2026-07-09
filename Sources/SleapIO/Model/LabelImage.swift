import Foundation

/// Per-pixel object segmentation for a single video frame.
///
/// Each pixel of ``data`` is either background (`0`) or a positive integer label
/// identifying the object occupying that pixel. Unlike a binary
/// ``SegmentationMask`` (one mask per object), a single `LabelImage` stores every
/// object for a frame in one dense integer array — the standard output of
/// instance-segmentation tools such as Cellpose and StarDist.
///
/// Mirrors Python sleap-io's `sleap_io.model.label_image.LabelImage` (with its
/// inner `LabelImage.Info`). Two intentional adaptations follow the sibling
/// annotation value types (``BoundingBox`` / ``Centroid`` / ``SegmentationMask``):
///
/// - This is a value type rather than a class, and object metadata references
///   videos/tracks/instances by **index** (``videoIndex`` / ``Info/trackIndex`` /
///   ``Info/instanceIndex``) into the parent ``Labels`` tables rather than by
///   object pointer, so the type carries no object-graph aliasing.
/// - ``data`` is stored row-major and flat (`count == height * width`) rather than
///   as a 2-D array, matching the on-disk layout.
///
/// - Note: Upstream defines only `LabelImage` (no `PredictedLabelImage`); the
///   per-object ``Info`` metadata is where richness lives, so no predicted
///   variant is modeled here.
///
/// Persisted to the `/label_images` (+ `/label_image_objects`,
/// `/label_image_data`) datasets of an SLP file.
public struct LabelImage: Hashable, Codable, Sendable {

    /// Metadata for one segmented object within a ``LabelImage``.
    ///
    /// Mirrors Python's `LabelImage.Info`. Track and pose-instance associations
    /// are stored as indices into the parent ``Labels/tracks`` /
    /// ``Labels/labeledFrames`` tables (or `nil` when unset).
    public struct Info: Hashable, Codable, Sendable {
        /// Index of the associated track in ``Labels/tracks``, or `nil` if untracked.
        public var trackIndex: Int?
        /// Semantic class label (e.g. `"neuron"`, `"glia"`); `""` when unset.
        public var category: String
        /// Human-readable name (e.g. `"cell_042"`); `""` when unset.
        public var name: String
        /// Index of a linked pose instance, or `nil` if none.
        public var instanceIndex: Int?

        public init(
            trackIndex: Int? = nil,
            category: String = "",
            name: String = "",
            instanceIndex: Int? = nil
        ) {
            self.trackIndex = trackIndex
            self.category = category
            self.name = name
            self.instanceIndex = instanceIndex
        }
    }

    /// Row-major integer pixel labels of length `height * width`. `0` is
    /// background; positive values are object IDs.
    public var data: [Int32]
    /// Image height in pixels.
    public var height: Int
    /// Image width in pixels.
    public var width: Int

    /// Mapping from label ID to object metadata. Label IDs not present are
    /// treated as having default (empty) ``Info``.
    public var objects: [Int: Info]

    /// Index of the associated video in ``Labels/videos``, or `nil`.
    public var videoIndex: Int?
    /// Frame index within the video, or `nil` (a static label image that applies
    /// to all frames, matching Python's `frame_idx = None`).
    public var frameIndex: Int?
    /// Annotation source identifier; `""` when unset.
    public var source: String

    public init(
        data: [Int32],
        height: Int,
        width: Int,
        objects: [Int: Info] = [:],
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        source: String = ""
    ) {
        self.data = data
        self.height = height
        self.width = width
        self.objects = objects
        self.videoIndex = videoIndex
        self.frameIndex = frameIndex
        self.source = source
    }

    // MARK: - Convenience

    /// Number of object-metadata entries (mirrors Python's `n_objects`, i.e.
    /// `len(objects)`, which may differ from the count of distinct pixel labels).
    public var objectCount: Int { objects.count }

    /// Sorted unique non-zero label values present in ``data``.
    public var labelIDs: [Int] {
        var seen = Set<Int32>()
        for value in data where value > 0 { seen.insert(value) }
        return seen.map(Int.init).sorted()
    }

    /// Build a label image from a 2-D row-major array of label values.
    ///
    /// Every row must have the same length (the image width); an empty array
    /// yields a `0 × 0` image.
    public static func from(
        rows: [[Int32]],
        objects: [Int: Info] = [:],
        videoIndex: Int? = nil,
        frameIndex: Int? = nil,
        source: String = ""
    ) -> LabelImage {
        let height = rows.count
        let width = rows.first?.count ?? 0
        var flat: [Int32] = []
        flat.reserveCapacity(height * width)
        for row in rows { flat.append(contentsOf: row) }
        return LabelImage(
            data: flat, height: height, width: width, objects: objects,
            videoIndex: videoIndex, frameIndex: frameIndex, source: source)
    }
}

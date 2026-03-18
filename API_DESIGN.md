// ============================================================================
// sleap-io.swift — Public API Design
// ============================================================================
//
// This file defines the complete public API surface for sleap-io.swift.
// It is not compilable implementation code — it is a design specification
// expressed as Swift declarations.
//
// Design principles:
//   1. Reference types for identity objects (things that are shared/pointed-to)
//   2. Value types for data (points, edges, geometry)
//   3. Lazy loading is transparent, not a separate type hierarchy
//   4. HDF5 is an implementation detail — never exposed publicly
//   5. Apple-only (AVFoundation, CoreGraphics, Metal, Accelerate)
//   6. Swift concurrency (async/await, Sendable) from day one
//   7. No broad Codable on identity types — explicit codecs preserve graph identity


// ============================================================================
// MARK: - Module Structure
// ============================================================================
//
// Package.swift targets:
//
//   SleapIO          — Core model types, codecs, transforms.
//                      May use Foundation and Apple frameworks (Accelerate, etc.).
//                      This is what everything imports.
//
//   SleapHDF5        — HDF5 wrapper + SLP read/write + lazy loading backend.
//                      Depends on CHDF5 (system library target wrapping libhdf5).
//                      Downstream apps import this to load .slp files but never
//                      touch HDF5 types directly — they get back SleapIO types.
//
//   SleapVideo       — Video abstraction + AVFoundation backend.
//
//   SleapRendering   — 2D rendering of skeletons/instances onto frames.
//                      CoreGraphics, optionally Metal.
//
//   CHDF5            — System library target. Module map for libhdf5.
//
// All modules target Apple platforms (macOS + iPadOS).
//
// Dependency graph:
//
//   SleapRendering --> SleapVideo --> SleapIO
//   SleapHDF5 -----> SleapIO
//   SleapHDF5 -----> CHDF5
//
// A downstream app like sleap-label.swift imports all four.


// ============================================================================
// MARK: - Point Storage
// ============================================================================
//
// Decision: Interleaved xy buffer with separate metadata arrays.
//
// Layout: coordinates is a single ContiguousArray<Float> of interleaved
// [x0, y0, x1, y1, ...]. Visibility and completeness are separate arrays.
//
// Rationale:
//   - Float32 (not Float64) because all downstream consumers are GPU-bound
//     (Metal, CoreML) and HDF5 point data is typically float64 but gets
//     truncated anyway. We convert on read.
//   - Interleaved xy (not separate x/y) because:
//       (a) Keeps each point's x,y on the same cache line
//       (b) Matches Metal's packed_float2 layout for zero-copy GPU upload
//       (c) Halves array count vs separate x/y arrays
//       (d) Matches the dominant access pattern (read all coords of one instance)
//   - Visibility/completeness are separate because they have different types
//     (Bool vs Float) and different access patterns than coordinates.
//   - HDF5 stores x and y as separate compound fields (float64). On read,
//     we extract both fields and interleave into the Float32 coordinate buffer.
//   - The PointsArray wrapper provides subscript-by-Node ergonomics on top.

/// A single 2D point. Value type used for individual point access.
public struct Point: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var visible: Bool
    public var complete: Bool

    public init(x: Float, y: Float, visible: Bool = true, complete: Bool = false)

    /// SIMD representation for math operations.
    public var simd: SIMD2<Float> { get set }
}

/// A single predicted point with a confidence score.
public struct PredictedPoint: Hashable, Codable, Sendable {
    public var point: Point
    public var score: Float

    public var x: Float { get set }
    public var y: Float { get set }
    public var visible: Bool { get set }
    public var complete: Bool { get set }
}

/// Contiguous storage for N points belonging to one instance.
///
/// Backed by contiguous Float32 buffers for GPU/Accelerate compatibility.
/// Subscriptable by integer index or by `Node` (when a skeleton is associated).
public struct PointsArray: Sendable {
    /// Number of points (== number of nodes in the skeleton).
    public var count: Int { get }

    /// Interleaved xy coordinates as [x0, y0, x1, y1, ...]. Length = count * 2.
    /// Directly usable as a Metal vertex buffer source.
    /// ContiguousArray guarantees no NSArray bridging overhead.
    public var coordinates: ContiguousArray<Float> { get set }

    /// Per-point visibility. Length = count.
    public var visibility: ContiguousArray<Bool> { get set }

    /// Per-point completeness. Length = count.
    public var completeness: ContiguousArray<Bool> { get set }

    // --- Subscript by index ---
    public subscript(index: Int) -> Point { get set }

    // --- Subscript by Node (requires skeleton context) ---
    public subscript(node: Node) -> Point { get set }
    public subscript(name: String) -> Point { get set }

    // --- Bulk SIMD access ---
    /// All xy as SIMD2 array. Useful for transform math.
    public var simdCoordinates: [SIMD2<Float>] { get }

    // --- Factory ---
    public init(count: Int)
    public init(points: [Point])

    /// Create from raw coordinate data (used by the SLP reader during materialization).
    /// Copies the provided data into owned storage.
    public init(coordinates: ContiguousArray<Float>,
                visibility: ContiguousArray<Bool>,
                completeness: ContiguousArray<Bool>)
}

/// Extends PointsArray with per-point confidence scores.
public struct PredictedPointsArray: Sendable {
    public var points: PointsArray
    public var scores: [Float]

    public var count: Int { get }

    public subscript(index: Int) -> PredictedPoint { get set }
    public subscript(node: Node) -> PredictedPoint { get set }
    public subscript(name: String) -> PredictedPoint { get set }

    public init(count: Int)
    public init(points: [PredictedPoint])
}


// ============================================================================
// MARK: - Skeleton Types
// ============================================================================
//
// Decision: Skeleton is a class (identity type, shared across instances).
// Node is a class (identity type, shared across edges/symmetries/skeleton).
// Edge and Symmetry are structs (value types describing relationships).
//
// Rationale:
//   - A Skeleton is referenced by every Instance that uses it. Mutations to
//     the skeleton (adding a node) must be visible everywhere. Class semantics.
//   - A Node is referenced by name in edges, symmetries, and point lookups.
//     Identity matters — two nodes with the same name on different skeletons
//     are different objects. Class semantics.
//   - Edge and Symmetry are just pairs of node references. They don't have
//     independent identity. Struct semantics.

/// A named landmark in a skeleton. Identity type.
/// Not Codable — serialized via explicit codecs that preserve identity.
public final class Node: Hashable, Sendable {
    public let name: String

    public init(name: String)

    // Identity-based equality (=== under the hood via ObjectIdentifier).
    public static func == (lhs: Node, rhs: Node) -> Bool
    public func hash(into hasher: inout Hasher)
}

/// A directed connection between two nodes.
public struct Edge: Hashable, Sendable {
    public var source: Node
    public var destination: Node

    public init(source: Node, destination: Node)
}

/// A symmetry relationship between two nodes (e.g., left_eye <-> right_eye).
public struct Symmetry: Hashable, Sendable {
    public var nodes: (Node, Node)

    public init(_ a: Node, _ b: Node)
}

/// A named directed graph of body part landmarks.
///
/// Identity type — shared by reference across all instances that use it.
/// Conforms to `RandomAccessCollection` over its nodes for convenience.
/// Not Codable — serialized via SkeletonCodec (legacy NetworkX graph format for SLP).
public final class Skeleton: Hashable, @unchecked Sendable {
    public var name: String
    public var nodes: [Node] { get }
    public var edges: [Edge] { get }
    public var symmetries: [Symmetry] { get }

    public init(name: String, nodes: [Node] = [], edges: [Edge] = [], symmetries: [Symmetry] = [])

    // --- Node management ---
    public func addNode(_ node: Node)
    public func addNode(named name: String) -> Node
    public func removeNode(_ node: Node)

    // --- Edge management ---
    public func addEdge(from source: Node, to destination: Node)
    public func removeEdge(_ edge: Edge)

    // --- Symmetry management ---
    public func addSymmetry(_ a: Node, _ b: Node)
    public func removeSymmetry(_ symmetry: Symmetry)

    // --- Lookup ---
    /// O(1) lookup by name. Returns nil if no node with that name exists.
    public func node(named name: String) -> Node?

    /// O(1) index of a node. Returns nil if the node is not in this skeleton.
    public func index(of node: Node) -> Int?

    // Identity-based equality.
    public static func == (lhs: Skeleton, rhs: Skeleton) -> Bool
    public func hash(into hasher: inout Hasher)
}

// Skeleton as a collection of nodes.
extension Skeleton: RandomAccessCollection {
    public typealias Element = Node
    public typealias Index = Int
    public var startIndex: Int { get }
    public var endIndex: Int { get }
    public subscript(position: Int) -> Node { get }
}


// ============================================================================
// MARK: - Track
// ============================================================================
//
// Decision: Class. A Track is an identity-bearing label shared by many
// instances across frames. Renaming a track must propagate everywhere.

/// An identity label for linking instances across frames.
/// Not Codable — serialized via explicit codecs that preserve identity.
public final class Track: Hashable, @unchecked Sendable {
    public var name: String

    public init(name: String)

    // Identity-based equality.
    public static func == (lhs: Track, rhs: Track) -> Bool
    public func hash(into hasher: inout Hasher)
}


// ============================================================================
// MARK: - Instance Types
// ============================================================================
//
// Decision: Class. Instances are reference types because:
//   - They live in a mutable object graph (LabeledFrame -> Instance -> Skeleton/Track)
//   - PredictedInstance extends Instance (class inheritance, not protocol)
//   - They carry mutable state (points, track assignment)
//   - Identity matters for undo/redo in the annotation GUI

/// A single pose instance (set of landmark points) within a frame.
public class Instance: Hashable, @unchecked Sendable {
    /// The landmark points for this instance.
    public var points: PointsArray { get set }

    /// The skeleton defining the landmark topology.
    public let skeleton: Skeleton

    /// The track this instance belongs to, if any.
    public var track: Track? { get set }

    /// Tracking confidence score (from tracker, not pose model).
    public var trackingScore: Float? { get set }

    /// If this instance was created from a predicted instance, reference to it.
    public weak var fromPredicted: PredictedInstance? { get set }

    public init(skeleton: Skeleton,
                points: PointsArray? = nil,
                track: Track? = nil,
                trackingScore: Float? = nil,
                fromPredicted: PredictedInstance? = nil)

    // --- Point access by node ---
    /// Subscript by Node for ergonomic point access.
    /// `instance[node] = Point(x: 10, y: 20)`
    public subscript(node: Node) -> Point { get set }

    /// Subscript by node name.
    /// `instance["nose"] = Point(x: 10, y: 20)`
    public subscript(name: String) -> Point { get set }

    // --- Geometry ---
    /// Axis-aligned bounding box of visible points.
    public var boundingBox: CGRect? { get }

    /// Whether this instance's visible points overlap with another's bounding box.
    public func overlaps(with other: Instance) -> Bool

    // Identity-based equality.
    public static func == (lhs: Instance, rhs: Instance) -> Bool
    public func hash(into hasher: inout Hasher)
}

/// A pose instance produced by a prediction model, with a confidence score.
public final class PredictedInstance: Instance {
    /// Model confidence score for this instance.
    public var score: Float

    /// Per-point predicted points with scores.
    public var predictedPoints: PredictedPointsArray { get set }

    public init(skeleton: Skeleton,
                points: PredictedPointsArray,
                score: Float,
                track: Track? = nil,
                trackingScore: Float? = nil)
}


// ============================================================================
// MARK: - Video
// ============================================================================
//
// Decision: Video is a class (identity type, shared across labeled frames).
// The backend is protocol-based so we can swap AVFoundation, HDF5 embedded
// video, image sequences, and future backends without changing the Video type.
//
// Frame access is async because video decoding is inherently I/O-bound and
// must not block the main thread on iPadOS.

/// A video source providing frame images.
public final class Video: Hashable, @unchecked Sendable {
    /// Original imported or decoded path from the source dataset.
    public let originalFilename: String

    /// Optional persisted override that should be written back on save.
    /// Used for permanent relocation without discarding provenance.
    public var persistedFilename: String? { get set }

    /// Effective active path used for open/save/export behavior.
    /// Resolves to `persistedFilename ?? originalFilename`.
    public var filename: String { get }

    /// Number of frames, or nil if unknown until opened.
    public var frameCount: Int? { get }

    /// Frame dimensions (height, width, channels), or nil if unknown.
    public var frameSize: (height: Int, width: Int, channels: Int)? { get }

    /// The original source video, if this is a derived/embedded copy.
    public var sourceVideo: Video? { get }

    /// Backend type identifier (e.g., "media", "hdf5", "imageSequence").
    public var backendType: String { get }

    public init(filename: String)

    /// Temporary relocation is session-only opener/runtime state and must not
    /// mutate `persistedFilename`.
    ///
    /// Permanent relocation sets `persistedFilename` and preserves
    /// `originalFilename`.

    // --- Frame access (async) ---
    /// Load a single frame as a platform image.
    /// On Apple platforms, returns CGImage. Throws on invalid index or I/O error.
    public func frame(at index: Int) async throws -> CGImage

    /// Load multiple frames. More efficient than individual calls for
    /// sequential access patterns (the backend can pipeline).
    public func frames(at indices: Range<Int>) async throws -> [CGImage]

    /// Prefetch hint — tells the backend to warm caches for these indices.
    /// Non-blocking, best-effort.
    public func prefetch(indices: IndexSet)

    // Identity-based equality.
    public static func == (lhs: Video, rhs: Video) -> Bool
    public func hash(into hasher: inout Hasher)
}

/// Protocol for video decoding backends. Internal to SleapVideo module.
/// Not part of the public API — downstream apps interact with `Video` only.
public protocol VideoBackend: Sendable {
    var frameCount: Int? { get }
    var frameSize: (height: Int, width: Int, channels: Int)? { get }
    func frame(at index: Int) async throws -> CGImage
    func frames(at indices: Range<Int>) async throws -> [CGImage]
    func prefetch(indices: IndexSet)
}


// ============================================================================
// MARK: - LabeledFrame
// ============================================================================
//
// Decision: Class. A LabeledFrame is a mutable container in the object graph.
// It references a Video (by reference) and holds a list of Instances.

/// A single video frame with associated pose instances.
public final class LabeledFrame: Hashable, @unchecked Sendable {
    /// The video this frame belongs to.
    public let video: Video

    /// The frame index within the video.
    public let frameIndex: Int

    /// The instances in this frame.
    public var instances: [Instance] { get set }

    /// Whether this frame is explicitly marked as having no instances.
    public var isNegative: Bool { get set }

    public init(video: Video, frameIndex: Int, instances: [Instance] = [])

    /// All user-labeled (non-predicted) instances.
    public var userInstances: [Instance] { get }

    /// All predicted instances.
    public var predictedInstances: [PredictedInstance] { get }

    /// Check if this frame has any user-labeled instances.
    public var hasUserInstances: Bool { get }

    // --- Merge strategies ---
    /// Strategy for resolving conflicts when merging instances into this frame.
    public enum MergeStrategy: Sendable {
        case auto
        case keepOriginal
        case keepNew
        case keepBoth
        case updateTracks
        case replacePredictions
    }

    /// Merge instances from another frame into this one.
    public func merge(from other: LabeledFrame, strategy: MergeStrategy = .auto)

    // Identity-based equality (=== via ObjectIdentifier), matching Python's eq=False.
    public static func == (lhs: LabeledFrame, rhs: LabeledFrame) -> Bool
    public func hash(into hasher: inout Hasher)
}


// ============================================================================
// MARK: - Camera & Multi-View
// ============================================================================
//
// Decision: Camera is a class (identity type, shared across recording sessions).
// RecordingSession, FrameGroup, InstanceGroup are classes (mutable containers
// in the object graph with shared references).

/// Camera intrinsic and extrinsic parameters.
/// Not Codable — serialized via explicit codecs that preserve identity.
public final class Camera: Hashable, @unchecked Sendable {
    public var name: String
    /// 3x3 intrinsic matrix as row-major [Float]. Length = 9.
    public var matrix: [Float]?
    /// Distortion coefficients.
    public var distortionCoefficients: [Float]?
    /// Image size (width, height).
    public var size: (width: Int, height: Int)?
    /// Rotation vector (Rodrigues).
    public var rvec: [Float]?
    /// Translation vector.
    public var tvec: [Float]?

    public init(name: String)

    /// Compute the 3x4 extrinsic matrix from rvec/tvec.
    public var extrinsicMatrix: [Float]? { get }

    // Identity-based equality.
    public static func == (lhs: Camera, rhs: Camera) -> Bool
    public func hash(into hasher: inout Hasher)
}

/// A multi-camera recording session mapping cameras to videos.
public final class RecordingSession: @unchecked Sendable {
    /// Map from camera to its corresponding video in this session.
    public var cameraToVideo: [Camera: Video] { get set }

    /// Synchronized frame groups across cameras.
    public var frameGroups: [FrameGroup] { get set }

    public init(cameraToVideo: [Camera: Video] = [:])
}

/// A group of synchronized frames across multiple cameras.
public final class FrameGroup: @unchecked Sendable {
    /// The labeled frames from each camera view, keyed by camera.
    public var frames: [Camera: LabeledFrame] { get set }

    /// Instance correspondences across views.
    public var instanceGroups: [InstanceGroup] { get set }

    public init()
}

/// A group of corresponding instances across camera views.
public final class InstanceGroup: @unchecked Sendable {
    /// Corresponding instances keyed by camera.
    public var instances: [Camera: Instance] { get set }

    public init()
}


// ============================================================================
// MARK: - ROI & Segmentation Masks
// ============================================================================
//
// Decision: Struct for both. These are data containers, not identity objects.
// They can be freely copied and compared by value.

/// The type of spatial annotation.
public enum AnnotationType: String, Codable, Sendable {
    case boundingBox = "bounding_box"
    case polygon = "polygon"
    case polyline = "polyline"
    case point = "point"
    case ellipse = "ellipse"
    case segmentationMask = "segmentation_mask"
}

/// A region of interest defined by geometry.
public struct ROI: Hashable, Codable, Sendable {
    public var annotationType: AnnotationType
    public var name: String
    public var category: String?
    public var score: Float?
    public var source: String?

    /// The geometry as a list of (x, y) coordinates.
    /// Interpretation depends on annotationType:
    ///   - boundingBox: [topLeft, bottomRight] (2 points)
    ///   - polygon/polyline: ordered vertex list
    ///   - point: single point
    ///   - ellipse: [center, radiusPoint] (2 points)
    public var points: [SIMD2<Float>]

    /// Video/frame/track/instance associations (optional context).
    public var videoIndex: Int?
    public var frameIndex: Int?
    public var trackIndex: Int?
    public var instanceIndex: Int?

    public init(annotationType: AnnotationType, name: String, points: [SIMD2<Float>])

    /// Axis-aligned bounding box enclosing the geometry.
    public var boundingBox: CGRect { get }

    /// Test whether a point is inside this ROI.
    public func contains(_ point: SIMD2<Float>) -> Bool
}

/// A run-length encoded binary segmentation mask.
public struct SegmentationMask: Hashable, Codable, Sendable {
    public var annotationType: AnnotationType
    public var name: String
    public var category: String?
    public var score: Float?
    public var source: String?

    /// RLE-encoded counts (COCO-style).
    public var rleCounts: [Int]
    public var height: Int
    public var width: Int

    public var videoIndex: Int?
    public var frameIndex: Int?
    public var trackIndex: Int?
    public var instanceIndex: Int?

    public init(rleCounts: [Int], height: Int, width: Int, name: String)

    /// Decode to a dense boolean mask. `true` = foreground.
    public func decode() -> [[Bool]]

    /// Encode from a dense boolean mask.
    public static func encode(mask: [[Bool]], name: String) -> SegmentationMask
}


// ============================================================================
// MARK: - Suggestion
// ============================================================================
//
// Decision: Struct. A suggestion is just a (video, frameIndex) pair with
// optional grouping metadata. No identity semantics needed.

/// A suggested frame for labeling.
/// Not Codable — contains a Video reference (identity type).
/// Serialized via explicit codecs (video index + frame index).
public struct SuggestionFrame: Hashable, Sendable {
    public var video: Video
    public var frameIndex: Int
    public var group: String?

    public init(video: Video, frameIndex: Int, group: String? = nil)
}


// ============================================================================
// MARK: - Labels (Top-Level Container)
// ============================================================================
//
// Decision: Class. Labels is the root of the entire object graph. It is the
// mutable document model. It owns all the collections and provides the
// primary API for querying and modifying the dataset.
//
// Labels conforms to RandomAccessCollection<LabeledFrame> for ergonomic
// iteration, but also exposes richer query APIs.
//
// Lazy loading rules:
//   - The RandomAccessCollection subscript returns cached, identity-stable
//     LabeledFrame objects: the same index always returns the same object.
//   - Cached frames and their instances are fully mutable (edit points,
//     change tracks, add/remove instances within a frame).
//   - STRUCTURAL mutations on Labels (addFrame, removeFrame, etc.) require
//     materialized state and throw if called while lazy.
//   - Call materialize() to transition to a fully mutable, eagerly loaded state.
//   - There is no `labeledFrames` stored property. Frame access goes through
//     the collection subscript or query methods. This avoids the problem of
//     a get/set [LabeledFrame] property that would force eager materialization
//     or have surprising semantics when lazy.

/// The top-level container for a SLEAP dataset.
///
/// This is the root of the object graph. It owns all labeled frames, videos,
/// skeletons, tracks, and associated metadata.
///
/// ```swift
/// let labels = try await Labels.load(from: url)
/// for frame in labels {
///     for instance in frame.instances {
///         let nose = instance["nose"]
///         print(nose.x, nose.y)
///     }
/// }
/// ```
public final class Labels: @unchecked Sendable {
    // --- Primary data ---
    // No public `labeledFrames` property. Access frames via the
    // RandomAccessCollection subscript or the query methods below.
    // This enables transparent lazy loading without a surprising
    // get/set property that would force eager materialization.

    // --- Identity tables ---
    // These are the shared reference tables that uncached column store rows
    // index into. Their order and contents must remain stable while lazy,
    // because uncached frames/instances contain raw integer indices into
    // these arrays. Read-only properties; mutation via throwing setters.
    public var videos: [Video] { get }
    public var skeletons: [Skeleton] { get }
    public var tracks: [Track] { get }

    /// Replace the videos list. Throws `mutationWhileLazy` if `isLazy`.
    public func setVideos(_ videos: [Video]) throws
    /// Replace the skeletons list. Throws `mutationWhileLazy` if `isLazy`.
    public func setSkeletons(_ skeletons: [Skeleton]) throws
    /// Replace the tracks list. Throws `mutationWhileLazy` if `isLazy`.
    public func setTracks(_ tracks: [Track]) throws

    // --- Metadata (freely mutable even while lazy) ---
    public var suggestions: [SuggestionFrame] { get set }
    public var sessions: [RecordingSession] { get set }
    public var provenance: [String: String] { get set }
    public var rois: [ROI] { get set }
    public var masks: [SegmentationMask] { get set }

    public init()

    // --- Query ---
    /// All labeled frames for a given video, sorted by frame index.
    public func frames(for video: Video) -> [LabeledFrame]

    /// The labeled frame for a specific video and frame index, if it exists.
    /// Returns the cached object — same call returns same identity.
    public func frame(for video: Video, at frameIndex: Int) -> LabeledFrame?

    /// All instances across all frames that belong to a given track.
    public func instances(for track: Track) -> [Instance]

    /// All unique frame indices that have labels for a given video.
    public func labeledFrameIndices(for video: Video) -> IndexSet

    // --- Structural mutation (requires materialized state) ---
    // These methods alter the frame list or identity tables (add/remove
    // frames, bulk operations across all frames). They throw
    // SleapIOError.mutationWhileLazy if called while lazy because they
    // cannot be reconciled with the partially-materialized column store.
    // Call materialize() first.
    //
    // Note: mutating individual cached frames/instances (changing points,
    // reassigning tracks, editing instances within a frame) is always
    // allowed and does not require materialize().

    /// Add a labeled frame, inserting the video/skeleton/tracks if new.
    /// - Throws: `SleapIOError.mutationWhileLazy` if `isLazy`.
    public func addFrame(_ frame: LabeledFrame) throws

    /// Remove a labeled frame.
    /// - Throws: `SleapIOError.mutationWhileLazy` if `isLazy`.
    public func removeFrame(_ frame: LabeledFrame) throws

    /// Remove all predicted instances from all frames.
    /// - Throws: `SleapIOError.mutationWhileLazy` if `isLazy`.
    public func clearPredictions() throws

    /// Remove all instances belonging to a given track, optionally
    /// removing the track itself from the tracks list.
    /// - Throws: `SleapIOError.mutationWhileLazy` if `isLazy`.
    public func removeTrack(_ track: Track, removeInstances: Bool = false) throws

    // --- Merge ---
    /// Merge another Labels into this one.
    /// - Throws: `SleapIOError.mutationWhileLazy` if `isLazy`.
    public func merge(from other: Labels, strategy: LabeledFrame.MergeStrategy = .auto) throws

    // --- Convenience ---
    /// The primary skeleton (first in the list), if any.
    public var skeleton: Skeleton? { get }

    /// The primary video (first in the list), if any.
    public var video: Video? { get }

    /// Total number of labeled frames.
    public var frameCount: Int { get }

    /// Total number of instances across all frames.
    public var instanceCount: Int { get }

    /// Total number of predicted instances across all frames.
    public var predictedInstanceCount: Int { get }
}

// Labels as a collection of LabeledFrame.
// When lazy, the subscript returns identity-stable cached objects:
// labels[i] always returns the same LabeledFrame for the same i.
// Internally, the lazy store maintains a materialization cache keyed
// by frame row index. Once a frame is materialized, it is cached and
// subsequent accesses return the same object.
extension Labels: RandomAccessCollection {
    public typealias Element = LabeledFrame
    public typealias Index = Int
    public var startIndex: Int { get }
    public var endIndex: Int { get }
    public subscript(position: Int) -> LabeledFrame { get }
}


// ============================================================================
// MARK: - I/O: Loading & Saving
// ============================================================================
//
// Decision: Static async factory methods on Labels, not free functions.
// All file I/O is async because:
//   - HDF5 reads can be slow for large files
//   - We never want to block the main thread on iPadOS
//   - Lazy-loaded files need an open file handle managed internally
//
// The format is inferred from the file extension by default, but can be
// specified explicitly.
//
// Error handling: throws. File I/O has clear failure modes (file not found,
// corrupt data, unsupported format) that callers must handle. We don't use
// Result or optionals here.

/// Supported file formats.
public enum FileFormat: Sendable {
    case slp        // SLEAP HDF5 (.slp)
    case cocoJSON   // COCO keypoints (.json)
    case csv        // Flat CSV
    case labelStudio // Label Studio JSON
    case yolo       // Ultralytics YOLO directory format
    case analysisHDF5 // Analysis-only HDF5 (.h5)
}

/// Errors from I/O operations.
public enum SleapIOError: Error, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case corruptData(String)
    case hdf5Error(String)
    case videoError(String)
    case invalidSkeleton(String)
    case formatVersionTooNew(Float)
    case mutationWhileLazy(String)
}

extension Labels {
    // --- Loading ---

    /// Load labels from a file. Format is inferred from extension.
    ///
    /// For `.slp` files, this uses lazy loading by default: metadata and
    /// column arrays are loaded immediately (~100ms for a 180k-frame file),
    /// but individual LabeledFrame/Instance objects are materialized on access.
    ///
    /// - Parameters:
    ///   - url: File URL to load from.
    ///   - format: Explicit format override. Nil = infer from extension.
    /// - Returns: A fully or lazily loaded Labels instance.
    public static func load(from url: URL,
                            format: FileFormat? = nil) async throws -> Labels

    /// Load labels with progress reporting.
    public static func load(from url: URL,
                            format: FileFormat? = nil,
                            progress: @Sendable (Double) -> Void) async throws -> Labels

    // --- Saving ---

    /// Save labels to a file. Format is inferred from extension.
    public func save(to url: URL,
                     format: FileFormat? = nil) async throws

    /// Save with options (e.g., embed video frames, compress).
    public func save(to url: URL,
                     format: FileFormat? = nil,
                     options: SaveOptions = .defaults) async throws
}

/// Options controlling save behavior.
public struct SaveOptions: Sendable {
    /// Whether to embed labeled video frames into the .slp file.
    public var embedFrames: Bool

    /// Compression level for embedded frames (0.0 = no compression, 1.0 = max).
    public var compressionLevel: Float

    /// Image format for embedded frames.
    public var embeddedImageFormat: EmbeddedImageFormat

    public static let defaults: SaveOptions

    public enum EmbeddedImageFormat: Sendable {
        case png
        case jpeg(quality: Float)
    }
}


// ============================================================================
// MARK: - Lazy Loading
// ============================================================================
//
// Decision: SEMI-TRANSPARENT. Lazy loading is not a separate type, but it
// does have observable behavioral differences that callers must be aware of.
//
// When lazy:
//   - Frame access via subscript materializes and caches the LabeledFrame.
//     The same index always returns the same object (identity-stable).
//   - Cached frames and their instances are fully mutable. You can change
//     points, track assignments, add/remove instances within a frame, etc.
//     These mutations persist in the cache and are visible on subsequent
//     access and on save.
//   - STRUCTURAL mutation APIs on Labels (addFrame, removeFrame, clearPredictions,
//     removeTrack, merge) throw `mutationWhileLazy`. These require
//     materialize() because they alter the frame list itself, which cannot
//     be reconciled with the partially-materialized column store.
//   - Identity table mutations (setting videos, skeletons, tracks) also throw
//     `mutationWhileLazy`. Uncached column store rows contain raw integer
//     indices into these tables; mutating them would corrupt uncached data.
//   - On save: cached (materialized) frames are serialized from objects.
//     Uncached frames are serialized directly from the column store. This
//     is safe because uncached frames were never accessed or modified, and
//     the identity tables they reference are guaranteed unchanged.
//
// When materialized (after materialize() or for non-lazy formats):
//   - Full read/write access. All mutation APIs work.
//   - No lazy store or column arrays — pure object graph.
//
// Public surface:
//   1. Labels.load() — uses lazy loading by default for .slp files
//   2. labels.isLazy — check if the backing store is still lazy
//   3. labels.materialize() — forces full materialization, enables structural mutations

extension Labels {
    /// Whether this Labels instance is backed by lazy storage.
    /// Returns false after `materialize()` or for non-lazy formats.
    public var isLazy: Bool { get }

    /// Force materialization of all lazy data into in-memory objects.
    /// After this call, `isLazy` returns false and the file handle (if any)
    /// is released.
    ///
    /// This is useful before modifying the dataset or before closing the
    /// source file.
    public func materialize() async throws

    /// Materialize a specific range of frames (for partial loading).
    public func materialize(frameIndices: Range<Int>) async throws
}


// ============================================================================
// MARK: - Serialization Policy
// ============================================================================
//
// Identity types (Node, Skeleton, Track, Video, Camera, Instance, LabeledFrame,
// RecordingSession) do NOT conform to Codable. Naive Codable round-tripping
// would duplicate identity objects and break graph invariants (e.g., two
// instances referencing the "same" skeleton would get separate copies).
//
// Instead, serialization uses explicit codecs:
//   - SLP codec: custom HDF5 read/write preserving identity via index-based refs
//   - Dictionary codec: toDictionary() / fromDictionary() with explicit context
//   - COCO/LabelStudio/CSV codecs: format-specific serializers
//
// Codable is reserved for pure value types with no identity concerns:
//   - Point, PredictedPoint (coordinates + flags)
//   - ROI, SegmentationMask (geometry data, uses index refs not object refs)
//   - RenderOptions, SaveOptions (configuration values)
//   - AnnotationType, FileFormat (enums)


// ============================================================================
// MARK: - Dictionary Codec
// ============================================================================
//
// For interop with Python/JS and for the /metadata JSON blob, serialization
// uses an explicit codec object — not a per-type protocol — because graph
// types (Skeleton, Instance, Video, etc.) require shared identity tables
// during encode/decode to avoid duplicating objects.
//
// The codec object holds the identity context (lists of skeletons, videos,
// tracks) and converts between the object graph and index-based dict
// representations.

/// Codec for converting the Labels object graph to/from untyped dictionaries.
///
/// Holds shared identity tables so that encode/decode preserves object identity
/// (e.g., two instances referencing the same skeleton get the same Skeleton object
/// after round-tripping through dictionaries).
public struct DictionaryCodec {
    /// Encode a Labels to a dictionary hierarchy.
    public static func encode(_ labels: Labels) -> [String: Any]

    /// Decode a Labels from a dictionary hierarchy.
    public static func decode(_ dict: [String: Any]) throws -> Labels

    /// Encode a single Skeleton to a dictionary (e.g., for metadata JSON).
    /// Uses the legacy SLEAP/NetworkX graph format.
    public static func encodeSkeleton(_ skeleton: Skeleton) -> [String: Any]

    /// Decode a single Skeleton from a dictionary.
    public static func decodeSkeleton(_ dict: [String: Any]) throws -> Skeleton
}

// Value types (Point, ROI, SegmentationMask) can use Codable directly
// since they have no identity concerns. Graph types are always serialized
// through DictionaryCodec or format-specific codecs (SLP, COCO, etc.).


// ============================================================================
// MARK: - Transforms
// ============================================================================
//
// Geometric transforms operate on instances/points. They are free functions
// and Instance methods, not a separate transform pipeline object.

extension Instance {
    /// Return a new instance with all points translated by (dx, dy).
    public func translated(by offset: SIMD2<Float>) -> Instance

    /// Return a new instance with all points scaled relative to an origin.
    public func scaled(by factor: SIMD2<Float>, origin: SIMD2<Float> = .zero) -> Instance

    /// Return a new instance with all points rotated around an origin.
    public func rotated(by radians: Float, around origin: SIMD2<Float> = .zero) -> Instance

    /// Return a new instance cropped to a bounding box.
    /// Points outside the box are marked invisible.
    public func cropped(to rect: CGRect) -> Instance

    /// Apply an arbitrary 3x3 affine transform matrix (row-major).
    public func transformed(by matrix: [Float]) -> Instance
}

extension PointsArray {
    /// Apply an affine transform in-place.
    public mutating func apply(transform matrix: [Float])
}


// ============================================================================
// MARK: - Labels Splitting
// ============================================================================

/// A named collection of Labels for train/val/test splits.
public struct LabelsSet: Sendable {
    public var splits: [String: Labels]

    public init(_ splits: [String: Labels] = [:])

    public subscript(name: String) -> Labels? { get set }

    public var train: Labels? { get set }
    public var validation: Labels? { get set }
    public var test: Labels? { get set }
}

extension Labels {
    /// Split this Labels into train/validation/test sets.
    /// - Parameter ratios: e.g., ["train": 0.8, "val": 0.1, "test": 0.1]
    public func split(ratios: [String: Double], seed: UInt64? = nil) -> LabelsSet
}


// ============================================================================
// MARK: - Video Backend Protocol (SleapVideo module)
// ============================================================================
//
// These are in the SleapVideo module. The protocol is public so that
// downstream apps could theoretically provide custom backends, but the
// built-in backends are internal.
//
// Built-in backends (internal):
//   - AVFoundationBackend: mp4/avi/mov via AVAssetImageGenerator
//   - ImageSequenceBackend: directory of png/jpg/tif frames
//   - HDF5VideoBackend: embedded video in .slp files (SleapHDF5 provides this)

// (VideoBackend protocol defined above with Video)

extension Video {
    /// Subscript access to frames. Sugar for `try await video.frame(at:)`.
    /// Only usable in async contexts.
    public subscript(index: Int) -> CGImage {
        get async throws
    }
}


// ============================================================================
// MARK: - Concurrency Design Notes
// ============================================================================
//
// Thread safety model:
//
// 1. Model types (Labels, LabeledFrame, Instance, Skeleton, Track, Video)
//    are classes marked @unchecked Sendable. They are NOT thread-safe by
//    default. The expectation is that the annotation GUI serializes access
//    through a main-actor-bound document model.
//
// 2. Value types (Point, PointsArray, Edge, Symmetry, ROI, SegmentationMask)
//    are Sendable and freely shareable across concurrency domains.
//
// 3. File I/O (load/save) is async and internally dispatches to a background
//    executor. The returned Labels is safe to use from the calling context.
//
// 4. Video frame access is async. The Video class internally manages its
//    backend's concurrency (e.g., AVAssetImageGenerator is not thread-safe,
//    so Video serializes access internally).
//
// 5. For sleap-label.swift, the expected pattern is:
//
//    @MainActor
//    class Document: ObservableObject {
//        @Published var labels: Labels
//
//        func loadFile(_ url: URL) async throws {
//            labels = try await Labels.load(from: url)
//        }
//    }
//
// 6. For sleap.swift (training/inference), Labels can be passed between
//    tasks freely — the caller is responsible for not mutating from
//    multiple tasks simultaneously, same as any mutable reference type
//    in Swift.


// ============================================================================
// MARK: - Rendering (SleapRendering module)
// ============================================================================
//
// The rendering module provides 2D overlay rendering of skeletons/instances
// onto video frames. It uses CoreGraphics for CPU rendering and optionally
// Metal for GPU-accelerated batch rendering.

/// Configuration for rendering pose overlays.
public struct RenderOptions: Sendable {
    /// Node (landmark) marker radius in points.
    public var nodeRadius: CGFloat

    /// Edge (limb) line width in points.
    public var edgeWidth: CGFloat

    /// Color palette name (e.g., "alphabet", "catscale").
    public var palette: String

    /// Whether to draw node labels.
    public var showLabels: Bool

    /// Whether to draw track names.
    public var showTrackNames: Bool

    /// Whether to draw bounding boxes.
    public var showBoundingBoxes: Bool

    /// Opacity for predicted instances.
    public var predictionOpacity: CGFloat

    public static let defaults: RenderOptions
}

/// Renders pose overlays onto images.
public struct PoseRenderer: Sendable {
    public var options: RenderOptions

    public init(options: RenderOptions = .defaults)

    /// Render instances onto an image, returning a new composited image.
    public func render(instances: [Instance],
                       onto image: CGImage,
                       skeleton: Skeleton) -> CGImage

    /// Render instances into an existing CoreGraphics context.
    public func render(instances: [Instance],
                       in context: CGContext,
                       skeleton: Skeleton,
                       transform: CGAffineTransform)

    /// Render a full labeled frame (loads the video frame and composites).
    public func render(frame: LabeledFrame,
                       options: RenderOptions) async throws -> CGImage
}


// ============================================================================
// MARK: - Summary of Type Decisions
// ============================================================================
//
// CLASS (identity semantics, shared references):
//   Labels           — Root document, mutable container
//   LabeledFrame     — Mutable container in object graph
//   Instance         — Mutable, identity matters for GUI undo/redo
//   PredictedInstance — Subclass of Instance
//   Skeleton         — Shared across all instances using it
//   Node             — Shared across edges/symmetries/point lookups
//   Track            — Shared identity label across frames
//   Video            — Shared across labeled frames, manages backend lifecycle
//   Camera           — Shared across recording sessions
//   RecordingSession — Mutable multi-camera container
//   FrameGroup       — Mutable synchronized frame container
//   InstanceGroup    — Mutable cross-view correspondence
//
// STRUCT (value semantics, data):
//   Point            — Just coordinates + flags
//   PredictedPoint   — Point + score
//   PointsArray      — Interleaved xy coordinate buffer + separate metadata arrays
//   PredictedPointsArray — PointsArray + scores
//   Edge             — Pair of node references
//   Symmetry         — Pair of node references
//   ROI              — Geometry + metadata
//   SegmentationMask — RLE data + metadata
//   SuggestionFrame  — (video, frameIndex) pair
//   LabelsSet        — Named collection of Labels splits
//   RenderOptions    — Configuration value
//   SaveOptions      — Configuration value
//
// ENUM:
//   FileFormat       — Supported I/O formats
//   AnnotationType   — ROI/mask geometry type
//   SleapIOError     — Error cases
//   MergeStrategy    — Frame merge conflict resolution

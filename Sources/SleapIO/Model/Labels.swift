import Foundation

public typealias SleapIOWarning = RecoverableSleapError

/// Protocol for frame stores that can provide metadata without materialization.
public protocol FrameMetadataProvider {
    func frameMetadata() -> [(videoIndex: Int, frameIndex: Int)]
}

/// Protocol for the internal frame storage backing a Labels instance.
/// This enables transparent lazy vs eager frame access.
public protocol FrameStore: AnyObject, Sendable {
    var count: Int { get }
    func frame(at index: Int) -> LabeledFrame
    var isLazy: Bool { get }
    func allFrames() -> [LabeledFrame]

    /// Total instance count across all frames. O(1) for lazy stores (uses column store row count).
    var totalInstanceCount: Int { get }
    /// Total predicted instance count across all frames. O(1) for lazy stores.
    var totalPredictedInstanceCount: Int { get }
}

/// Eager frame store backed by a plain array.
public final class EagerFrameStore: FrameStore, @unchecked Sendable {
    public var frames: [LabeledFrame]

    public init(frames: [LabeledFrame] = []) {
        self.frames = frames
    }

    public var count: Int { frames.count }

    public func frame(at index: Int) -> LabeledFrame {
        frames[index]
    }

    public var isLazy: Bool { false }

    public func allFrames() -> [LabeledFrame] { frames }

    public var totalInstanceCount: Int {
        frames.reduce(0) { $0 + $1.instances.count }
    }

    public var totalPredictedInstanceCount: Int {
        frames.reduce(0) { $0 + $1.predictedInstances.count }
    }
}

/// The top-level container for a SLEAP dataset.
///
/// Root of the object graph. Owns all labeled frames, videos,
/// skeletons, tracks, and associated metadata.
///
/// ## Lazy vs Eager Mode
///
/// When loaded from an SLP file (the default), `Labels` uses lazy storage backed by
/// raw HDF5 column arrays. Frames are materialized into `LabeledFrame` objects on
/// first access and cached for identity stability.
///
/// ### Frame-local edits (work while lazy)
///
/// Once a frame has been accessed (and thus cached), its contents are fully mutable:
///
/// - **Point edits**: `instance[node] = point` or `instance.points[i] = point`
/// - **Track reassignment**: `instance.track = newTrack`
/// - **Adding/removing instances within a cached frame**: `frame.instances.append(inst)`
///   or `frame.instances.removeAll { $0 is PredictedInstance }`
///
/// These edits modify the cached objects in place and do not require materialization.
///
/// ### Labels-level mutations (require `materialize()` first)
///
/// Structural mutations that change the frame list or identity tables throw
/// ``SleapIOError/mutationWhileLazy(_:)`` unless the store has been fully materialized:
///
/// - `addFrame(_:)`, `removeFrame(_:)` -- modify the frame list
/// - `clearPredictions()` -- iterates and mutates all frames
/// - `merge(from:strategy:)` -- merges another Labels graph
/// - `setVideos(_:)`, `setSkeletons(_:)`, `setTracks(_:)` -- replace identity tables
///
/// Call ``materialize()`` to convert the lazy store into an eager array before
/// performing any of these operations.
public final class Labels: @unchecked Sendable {

    // MARK: - Internal frame storage

    /// The backing store for frame access. Can be eager or lazy.
    public var frameStore: FrameStore

    // MARK: - Identity tables

    private var _videos: [Video]
    private var _skeletons: [Skeleton]
    private var _tracks: [Track]

    public var videos: [Video] { _videos }
    public var skeletons: [Skeleton] { _skeletons }
    public var tracks: [Track] { _tracks }

    /// Replace the videos list. Throws `mutationWhileLazy` if `isLazy`.
    public func setVideos(_ videos: [Video]) throws {
        guard !isLazy else {
            throw SleapIOError.mutationWhileLazy("Cannot replace videos while lazy. Call materialize() first.")
        }
        _videos = videos
        invalidateFrameLookup()
    }

    /// Replace the skeletons list. Throws `mutationWhileLazy` if `isLazy`.
    public func setSkeletons(_ skeletons: [Skeleton]) throws {
        guard !isLazy else {
            throw SleapIOError.mutationWhileLazy("Cannot replace skeletons while lazy. Call materialize() first.")
        }
        _skeletons = skeletons
    }

    /// Replace the tracks list. Throws `mutationWhileLazy` if `isLazy`.
    public func setTracks(_ tracks: [Track]) throws {
        guard !isLazy else {
            throw SleapIOError.mutationWhileLazy("Cannot replace tracks while lazy. Call materialize() first.")
        }
        _tracks = tracks
    }

    // MARK: - Metadata (freely mutable)

    public var suggestions: [SuggestionFrame]
    public var sessions: [RecordingSession]
    public var provenance: [String: String]
    public var rois: [ROI]
    public var masks: [SegmentationMask]

    // MARK: - Init

    public init() {
        self.frameStore = EagerFrameStore()
        self._videos = []
        self._skeletons = []
        self._tracks = []
        self.suggestions = []
        self.sessions = []
        self.provenance = [:]
        self.rois = []
        self.masks = []
    }

    /// Internal initializer used by readers.
    public init(frameStore: FrameStore,
                videos: [Video],
                skeletons: [Skeleton],
                tracks: [Track],
                suggestions: [SuggestionFrame] = [],
                sessions: [RecordingSession] = [],
                provenance: [String: String] = [:],
                rois: [ROI] = [],
                masks: [SegmentationMask] = []) {
        self.frameStore = frameStore
        self._videos = videos
        self._skeletons = skeletons
        self._tracks = tracks
        self.suggestions = suggestions
        self.sessions = sessions
        self.provenance = provenance
        self.rois = rois
        self.masks = masks
    }

    // MARK: - Lazy loading

    /// Whether this Labels instance is backed by lazy storage.
    public var isLazy: Bool { frameStore.isLazy }

    /// Force materialization of all lazy data into in-memory objects.
    public func materialize() {
        guard isLazy else { return }
        let allFrames = frameStore.allFrames()
        frameStore = EagerFrameStore(frames: allFrames)
        // Frame order is preserved by allFrames(), but invalidate defensively so the
        // index is rebuilt against the eager store.
        invalidateFrameLookup()
    }

    // MARK: - Query

    /// All labeled frames for a given video, sorted by frame index.
    public func frames(for video: Video) -> [LabeledFrame] {
        var result: [LabeledFrame] = []
        for i in 0..<frameStore.count {
            let f = frameStore.frame(at: i)
            if f.video === video {
                result.append(f)
            }
        }
        return result.sorted { $0.frameIndex < $1.frameIndex }
    }

    /// The labeled frame for a specific video and frame index, if it exists.
    ///
    /// Backed by a cached `(videoIndex, frameIndex) -> store position` index that is
    /// built lazily on first use (via ``frameMetadata()``, so it does not materialize
    /// lazy frames) and invalidated on structural mutation. This makes repeated
    /// lookups O(1) instead of the previous O(n) linear scan.
    public func frame(for video: Video, at frameIndex: Int) -> LabeledFrame? {
        guard let videoIdx = videoIndex(of: video) else {
            return nil
        }
        guard let position = frameLookup()[FrameKey(video: videoIdx, frame: frameIndex)] else {
            return nil
        }
        return frameStore.frame(at: position)
    }

    /// Index of a video in the identity table by object identity, or `nil`.
    private func videoIndex(of video: Video) -> Int? {
        _videos.firstIndex { $0 === video }
    }

    // MARK: - Frame lookup index

    private struct FrameKey: Hashable {
        let video: Int
        let frame: Int
    }

    /// Cached `(videoIndex, frameIndex) -> store position` map. Invalidated by
    /// structural mutations (add/remove/merge/materialize/replace videos).
    private var _frameLookupCache: [FrameKey: Int]?

    private func frameLookup() -> [FrameKey: Int] {
        if let cache = _frameLookupCache { return cache }
        let meta = frameMetadata()
        var map = [FrameKey: Int](minimumCapacity: meta.count)
        for (position, m) in meta.enumerated() {
            // First occurrence wins, matching the previous linear-scan semantics.
            let key = FrameKey(video: m.videoIndex, frame: m.frameIndex)
            if map[key] == nil { map[key] = position }
        }
        _frameLookupCache = map
        return map
    }

    /// Invalidate the frame-lookup index. Call after any structural mutation that
    /// changes the frame list or the video ordering.
    private func invalidateFrameLookup() {
        _frameLookupCache = nil
    }

    /// All instances across all frames that belong to a given track.
    public func instances(for track: Track) -> [Instance] {
        var result: [Instance] = []
        for i in 0..<frameStore.count {
            let f = frameStore.frame(at: i)
            for inst in f.instances where inst.track === track {
                result.append(inst)
            }
        }
        return result
    }

    /// All unique frame indices that have labels for a given video.
    public func labeledFrameIndices(for video: Video) -> IndexSet {
        var indices = IndexSet()
        for i in 0..<frameStore.count {
            let f = frameStore.frame(at: i)
            if f.video === video {
                indices.insert(f.frameIndex)
            }
        }
        return indices
    }

    /// Frame metadata for index building.
    ///
    /// Returns `(videoIndex, frameIndex)` pairs for every labeled frame.
    /// When lazy, reads directly from the column store without materializing
    /// any frame objects. When eager, iterates materialized frames.
    public func frameMetadata() -> [(videoIndex: Int, frameIndex: Int)] {
        // Fast path: delegate to lazy store to avoid materializing frames
        if let lazyStore = frameStore as? FrameMetadataProvider {
            return lazyStore.frameMetadata()
        }

        // Eager path: iterate materialized frames
        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in _videos.enumerated() {
            videoIndexMap[ObjectIdentifier(v)] = i
        }

        var result = [(videoIndex: Int, frameIndex: Int)]()
        result.reserveCapacity(frameStore.count)
        for i in 0..<frameStore.count {
            let f = frameStore.frame(at: i)
            let vidIdx = videoIndexMap[ObjectIdentifier(f.video)] ?? 0
            result.append((videoIndex: vidIdx, frameIndex: f.frameIndex))
        }
        return result
    }

    // MARK: - Structural mutation (requires materialized state)

    private func requireMaterialized(_ operation: String) throws {
        guard !isLazy else {
            throw SleapIOError.mutationWhileLazy("Cannot \(operation) while lazy. Call materialize() first.")
        }
    }

    private var eagerStore: EagerFrameStore {
        frameStore as! EagerFrameStore
    }

    /// Add a labeled frame.
    public func addFrame(_ frame: LabeledFrame) throws {
        try requireMaterialized("add frame")
        eagerStore.frames.append(frame)
        invalidateFrameLookup()
        // Register new identity objects
        if !_videos.contains(where: { $0 === frame.video }) {
            _videos.append(frame.video)
        }
        for inst in frame.instances {
            if !_skeletons.contains(where: { $0 === inst.skeleton }) {
                _skeletons.append(inst.skeleton)
            }
            if let track = inst.track, !_tracks.contains(where: { $0 === track }) {
                _tracks.append(track)
            }
        }
    }

    /// Remove a labeled frame.
    public func removeFrame(_ frame: LabeledFrame) throws {
        try requireMaterialized("remove frame")
        eagerStore.frames.removeAll { $0 === frame }
        invalidateFrameLookup()
    }

    /// Remove all predicted instances from all frames.
    public func clearPredictions() throws {
        try requireMaterialized("clear predictions")
        for frame in eagerStore.frames {
            frame.instances.removeAll { $0 is PredictedInstance }
        }
    }

    /// Remove all instances belonging to a given track.
    public func removeTrack(_ track: Track, removeInstances: Bool = false) throws {
        try requireMaterialized("remove track")
        if removeInstances {
            for frame in eagerStore.frames {
                frame.instances.removeAll { $0.track === track }
            }
        } else {
            for frame in eagerStore.frames {
                for inst in frame.instances where inst.track === track {
                    inst.track = nil
                }
            }
        }
        _tracks.removeAll { $0 === track }
    }

    /// Merge another Labels into this one.
    @discardableResult
    public func merge(
        from other: Labels,
        strategy: LabeledFrame.MergeStrategy = .auto,
        errorMode: ErrorMode = .ignore
    ) throws -> [SleapIOWarning] {
        try requireMaterialized("merge")

        var collector = ErrorCollector()
        for incoming in other.skeletons {
            if !_skeletons.isEmpty && !_skeletons.contains(where: { $0.matches(incoming) }) {
                let error = RecoverableSleapError.skeletonMismatch(
                    expected: _skeletons.flatMap(\.nodeNames),
                    found: incoming.nodeNames
                )
                try collector.handle(error, mode: errorMode)
            }
        }

        // Merge identity tables
        for video in other.videos {
            if !_videos.contains(where: { $0 === video }) {
                _videos.append(video)
            }
        }
        for skeleton in other.skeletons {
            if !_skeletons.contains(where: { $0 === skeleton }) {
                _skeletons.append(skeleton)
            }
        }
        for track in other.tracks {
            if !_tracks.contains(where: { $0 === track }) {
                _tracks.append(track)
            }
        }
        // Merge frames
        for i in 0..<other.frameStore.count {
            let otherFrame = other.frameStore.frame(at: i)
            if let existing = frame(for: otherFrame.video, at: otherFrame.frameIndex) {
                existing.merge(from: otherFrame, strategy: strategy)
            } else {
                eagerStore.frames.append(otherFrame)
                // Keep the lookup index consistent so a later iteration that targets
                // the same (video, frameIndex) finds this newly appended frame.
                invalidateFrameLookup()
            }
        }

        return collector.errors
    }

    // MARK: - Convenience

    /// Whether any video in this dataset uses an embedded HDF5 backend.
    public var hasEmbeddedVideo: Bool {
        _videos.contains { $0.backendType.lowercased().hasPrefix("hdf5") }
    }

    /// The primary skeleton (first in the list), if any.
    public var skeleton: Skeleton? { _skeletons.first }

    /// The primary video (first in the list), if any.
    public var video: Video? { _videos.first }

    /// Total number of labeled frames.
    public var frameCount: Int { frameStore.count }

    /// Total number of instances across all frames.
    /// O(1) when lazy (uses column store row count without materializing frames).
    public var instanceCount: Int { frameStore.totalInstanceCount }

    /// Total number of predicted instances across all frames.
    /// O(1) when lazy (uses column store row count without materializing frames).
    public var predictedInstanceCount: Int { frameStore.totalPredictedInstanceCount }
}

// MARK: - RandomAccessCollection

extension Labels: RandomAccessCollection {
    public typealias Element = LabeledFrame
    public typealias Index = Int

    public var startIndex: Int { 0 }
    public var endIndex: Int { frameStore.count }

    public subscript(position: Int) -> LabeledFrame {
        frameStore.frame(at: position)
    }
}

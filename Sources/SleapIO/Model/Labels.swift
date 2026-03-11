import Foundation

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
    public func frame(for video: Video, at frameIndex: Int) -> LabeledFrame? {
        for i in 0..<frameStore.count {
            let f = frameStore.frame(at: i)
            if f.video === video && f.frameIndex == frameIndex {
                return f
            }
        }
        return nil
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
    public func merge(from other: Labels, strategy: LabeledFrame.MergeStrategy = .auto) throws {
        try requireMaterialized("merge")
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
            }
        }
    }

    // MARK: - Convenience

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

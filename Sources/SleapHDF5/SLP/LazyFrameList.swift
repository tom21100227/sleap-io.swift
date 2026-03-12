import Foundation
import SleapIO

/// A lazy frame list that materializes LabeledFrame objects on demand from column store data.
/// Conforms to FrameStore for use as the backing store in Labels.
/// Identity-stable: repeated access to the same index returns the same object.
public final class LazyFrameList: FrameStore, @unchecked Sendable {
    let store: LazyDataStore

    /// Cache of already-materialized frames. Keyed by row index.
    /// Ensures identity stability: labels[i] always returns the same object.
    private var cache: [Int: LabeledFrame] = [:]

    /// The set of indices that have been cached (for hybrid save).
    var cachedIndices: Set<Int> { Set(cache.keys) }

    /// Whether any frames have been cached.
    var hasCachedFrames: Bool { !cache.isEmpty }

    init(store: LazyDataStore) {
        self.store = store
    }

    // MARK: - FrameStore conformance

    public var count: Int { store.framesData.count }

    public func frame(at index: Int) -> LabeledFrame {
        if let cached = cache[index] { return cached }
        let frame = store.materializeFrame(at: index)
        cache[index] = frame
        return frame
    }

    public var isLazy: Bool { true }

    public func allFrames() -> [LabeledFrame] {
        (0..<count).map { frame(at: $0) }
    }

    /// Direct access to cached frame (nil if not yet materialized).
    func cachedFrame(at index: Int) -> LabeledFrame? {
        cache[index]
    }

    /// O(1) total instance count from column store.
    public var totalInstanceCount: Int {
        store.instancesData.count
    }

    /// O(1) predicted instance count from column store.
    public var totalPredictedInstanceCount: Int {
        var count = 0
        for i in 0..<store.instancesData.count {
            if store.instancesData.instanceType[i] != 0 {
                count += 1
            }
        }
        return count
    }
}

// MARK: - Lazy SLP reader

extension SLPReader {

    /// Read an SLP file with lazy loading (default mode).
    /// Only metadata and column arrays are loaded — frames are materialized on access.
    public static func readLazy(from path: String) async throws -> Labels {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SleapIOError.fileNotFound("File not found: \(path)")
        }

        let actor = try HDF5FileActor.openReadOnly(path: path)
        return try await actor.withFile { file in
            try readLazyFromFile(file)
        }
    }

    /// Read lazy from an open HDF5File (internal).
    static func readLazyFromFile(_ file: HDF5File) throws -> Labels {
        // 1. Read metadata
        let metadataGroup = try file.openGroup(name: "metadata")
        let formatId = try metadataGroup.readFloatAttribute(name: "format_id")

        if formatId > kMaxSupportedFormatVersion {
            throw SleapIOError.formatVersionTooNew(formatId)
        }

        let jsonStr = try metadataGroup.readStringAttribute(name: "json")
        let metadata = try SLPMetadata.parse(json: jsonStr, formatId: formatId)
        let skeletons = metadata.skeletons

        // 2. Read tracks & videos (always eager — small)
        let tracks = try readTracksInternal(from: file)
        let (videos, videoIdMap) = try SLPVideoTable.readVideosAndIdMap(from: file)

        // 3. Read column arrays (the bulk data — kept as raw arrays)
        let framesData = try readFrameColumns(from: file)
        let instancesData = try readInstanceColumns(from: file, formatId: formatId)
        let pointsData = try readPointColumns(from: file, name: "points")
        let predPointsData = try readPredPointColumns(from: file)
        try SLPVideoTable.validateReferencedVideoIDs(
            framesData.video,
            videoIdMap: videoIdMap,
            videoCount: videos.count
        )

        let negativeFrameSet = try readNegativeFrameSet(from: file, videoIdMap: videoIdMap, videoCount: videos.count)

        // 4. Create lazy store and frame list
        let store = LazyDataStore(
            framesData: framesData,
            instancesData: instancesData,
            pointsData: pointsData,
            predPointsData: predPointsData,
            videos: videos,
            skeletons: skeletons,
            tracks: tracks,
            formatId: formatId,
            videoIdMap: videoIdMap,
            negativeFrameSet: negativeFrameSet
        )

        let frameList = LazyFrameList(store: store)

        // 5. Read small metadata datasets (suggestions, sessions, etc.)
        let suggestions = try readSuggestionsInternal(from: file, videos: videos, videoIdMap: videoIdMap)
        let sessions = try readSessionsInternal(from: file, videos: videos, videoIdMap: videoIdMap)
        let rois = try readROIsInternal(from: file, formatId: formatId)
        let masks = try readMasksInternal(from: file, formatId: formatId)

        return Labels(
            frameStore: frameList,
            videos: videos,
            skeletons: skeletons,
            tracks: tracks,
            suggestions: suggestions,
            sessions: sessions,
            provenance: metadata.provenance,
            rois: rois,
            masks: masks
        )
    }

    // MARK: - Column readers

    private static func readFrameColumns(from file: HDF5File) throws -> FrameColumns {
        guard file.exists(name: "frames") else {
            return FrameColumns(video: [], frameIdx: [], instanceIdStart: [], instanceIdEnd: [])
        }
        let ds = try file.openDataset(name: "frames")
        let count = ds.count
        return FrameColumns(
            video: try ds.readCompoundFieldUInt32(fieldName: "video", count: count),
            frameIdx: try ds.readCompoundFieldUInt64(fieldName: "frame_idx", count: count),
            instanceIdStart: try ds.readCompoundFieldUInt64(fieldName: "instance_id_start", count: count),
            instanceIdEnd: try ds.readCompoundFieldUInt64(fieldName: "instance_id_end", count: count)
        )
    }

    private static func readInstanceColumns(from file: HDF5File, formatId: Float) throws -> InstanceColumns {
        guard file.exists(name: "instances") else {
            return InstanceColumns(instanceType: [], skeleton: [], track: [],
                                  fromPredicted: [], score: [], pointIdStart: [],
                                  pointIdEnd: [], trackingScore: [])
        }
        let ds = try file.openDataset(name: "instances")
        let count = ds.count

        let trackingScore: ContiguousArray<Float>
        if formatId >= 1.2 {
            trackingScore = try ds.readCompoundFieldFloat32(fieldName: "tracking_score", count: count)
        } else {
            trackingScore = ContiguousArray(repeating: 0.0, count: count)
        }

        return InstanceColumns(
            instanceType: try ds.readCompoundFieldUInt8(fieldName: "instance_type", count: count),
            skeleton: try ds.readCompoundFieldUInt32(fieldName: "skeleton", count: count),
            track: try ds.readCompoundFieldInt32(fieldName: "track", count: count),
            fromPredicted: try ds.readCompoundFieldInt64(fieldName: "from_predicted", count: count),
            score: try ds.readCompoundFieldFloat32(fieldName: "score", count: count),
            pointIdStart: try ds.readCompoundFieldUInt64(fieldName: "point_id_start", count: count),
            pointIdEnd: try ds.readCompoundFieldUInt64(fieldName: "point_id_end", count: count),
            trackingScore: trackingScore
        )
    }

    private static func readPointColumns(from file: HDF5File, name: String) throws -> PointColumns {
        guard file.exists(name: name) else {
            return PointColumns(x: [], y: [], visible: [], complete: [])
        }
        let ds = try file.openDataset(name: name)
        let count = ds.count
        return PointColumns(
            x: try ds.readCompoundFieldFloat64(fieldName: "x", count: count),
            y: try ds.readCompoundFieldFloat64(fieldName: "y", count: count),
            visible: try ds.readCompoundFieldBool(fieldName: "visible", count: count),
            complete: try ds.readCompoundFieldBool(fieldName: "complete", count: count)
        )
    }

    private static func readPredPointColumns(from file: HDF5File) throws -> PredPointColumns {
        guard file.exists(name: "pred_points") else {
            return PredPointColumns(x: [], y: [], visible: [], complete: [], scores: [])
        }
        let ds = try file.openDataset(name: "pred_points")
        let count = ds.count
        return PredPointColumns(
            x: try ds.readCompoundFieldFloat64(fieldName: "x", count: count),
            y: try ds.readCompoundFieldFloat64(fieldName: "y", count: count),
            visible: try ds.readCompoundFieldBool(fieldName: "visible", count: count),
            complete: try ds.readCompoundFieldBool(fieldName: "complete", count: count),
            scores: try ds.readCompoundFieldFloat64(fieldName: "score", count: count)
        )
    }

    private static func readNegativeFrameSet(
        from file: HDF5File,
        videoIdMap: [Int: Int],
        videoCount: Int
    ) throws -> Set<String> {
        guard file.exists(name: "negative_frames") else { return [] }
        let ds = try file.openDataset(name: "negative_frames")
        let count = ds.count
        guard count > 0 else { return [] }

        let videoIds = try ds.readCompoundFieldUInt32(fieldName: "video_id", count: count)
        let frameIdxs = try ds.readCompoundFieldUInt64(fieldName: "frame_idx", count: count)

        var result = Set<String>()
        for i in 0..<count {
            guard let vidIdx = SLPVideoTable.resolvedIndex(
                for: Int(videoIds[i]),
                videoIdMap: videoIdMap,
                videoCount: videoCount
            ) else {
                continue
            }
            result.insert("\(vidIdx)_\(frameIdxs[i])")
        }
        return result
    }

    // MARK: - Internal versions of existing readers (to avoid duplication)

    private static func readTracksInternal(from file: HDF5File) throws -> [Track] {
        guard file.exists(name: "tracks_json") else { return [] }
        let ds = try file.openDataset(name: "tracks_json")
        let strings = try ds.readVLenStrings()
        return try strings.map { str in
            guard let data = str.data(using: .utf8),
                  let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count >= 2,
                  let name = arr[1] as? String else {
                throw SleapIOError.corruptData("Invalid track JSON: \(str)")
            }
            return Track(name: name)
        }
    }

    private static func readSuggestionsInternal(
        from file: HDF5File, videos: [Video], videoIdMap: [Int: Int]
    ) throws -> [SuggestionFrame] {
        guard file.exists(name: "suggestions_json") else { return [] }
        let ds = try file.openDataset(name: "suggestions_json")
        let strings = try ds.readVLenStrings()
        var suggestions: [SuggestionFrame] = []
        for str in strings {
            guard let data = str.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let videoIdx = dict["video"] as? Int ?? 0
            let frameIdx = dict["frame_idx"] as? Int ?? 0
            let group = dict["group"] as? String
            guard let resolvedIdx = SLPVideoTable.resolvedIndex(
                for: videoIdx,
                videoIdMap: videoIdMap,
                videoCount: videos.count
            ) else {
                continue
            }
            suggestions.append(SuggestionFrame(video: videos[resolvedIdx], frameIndex: frameIdx, group: group))
        }
        return suggestions
    }

    private static func readSessionsInternal(
        from file: HDF5File, videos: [Video], videoIdMap: [Int: Int]
    ) throws -> [RecordingSession] {
        guard file.exists(name: "sessions_json") else { return [] }
        let ds = try file.openDataset(name: "sessions_json")
        let strings = try ds.readVLenStrings()
        var sessions: [RecordingSession] = []
        for str in strings {
            guard let data = str.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let session = RecordingSession()
            if let camVideos = dict["camera_to_video"] as? [[String: Any]] {
                for cv in camVideos {
                    let camName = cv["camera_name"] as? String ?? "camera"
                    let videoIdx = cv["video_idx"] as? Int ?? 0
                    let camera = Camera(name: camName)
                    guard let resolvedIdx = SLPVideoTable.resolvedIndex(
                        for: videoIdx,
                        videoIdMap: videoIdMap,
                        videoCount: videos.count
                    ) else {
                        continue
                    }
                    session.cameraToVideo[camera] = videos[resolvedIdx]
                }
            }
            sessions.append(session)
        }
        return sessions
    }

    private static func readROIsInternal(from file: HDF5File, formatId: Float) throws -> [ROI] {
        try readROIs(from: file, formatId: formatId)
    }

    private static func readMasksInternal(from file: HDF5File, formatId: Float) throws -> [SegmentationMask] {
        try readMasks(from: file, formatId: formatId)
    }
}

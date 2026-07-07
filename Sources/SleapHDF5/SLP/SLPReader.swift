import Foundation
import CHDF5
import SleapIO

/// Maximum supported SLP format version.
///
/// Files at or below this version load successfully. Versions 1.6-2.4 are read
/// on a best-effort basis: the reader materializes the datasets it models
/// (frames, instances, points, pred_points, videos and tracks) and silently
/// skips any datasets it does not model (see ``SLPReader/unmodeledDatasetNames``)
/// rather than rejecting the file. Only versions *strictly greater* than this
/// cap are rejected with ``SleapIOError/formatVersionTooNew``.
let kMaxSupportedFormatVersion: Float = 2.4

/// Reads SLEAP .slp files (HDF5-based).
public struct SLPReader {

    /// SLP datasets that format versions newer than 1.5 may contain and that
    /// this reader does not model. When a 1.6-2.4 file is loaded these datasets
    /// are skipped rather than causing a `formatVersionTooNew` failure: the
    /// reader materializes only the datasets it models — frames, instances,
    /// points, pred_points, videos and tracks. The ROI/segmentation-mask tables
    /// are modeled for the 1.5 schema only and are likewise skipped for newer
    /// versions (see ``modelsAnnotationTables(formatId:)``).
    ///
    /// The reader never opens these dataset names, so they are skipped by
    /// omission — no explicit branching is required. The list is retained for
    /// documentation and to anchor the version-support tests.
    static let unmodeledDatasetNames: [String] = [
        "bboxes", "masks", "centroids", "identities", "label_images"
    ]

    /// Validate an SLP `format_id` against the supported range.
    ///
    /// Versions at or below ``kMaxSupportedFormatVersion`` load successfully;
    /// versions 1.6-2.4 are read on a best-effort basis (see
    /// ``unmodeledDatasetNames``). Only versions *strictly greater* than the cap
    /// are rejected. Behavior for versions <= 1.5 is unchanged.
    ///
    /// - Throws: ``SleapIOError/formatVersionTooNew`` when `formatId` exceeds
    ///   ``kMaxSupportedFormatVersion``.
    static func validateFormatVersion(_ formatId: Float) throws {
        if formatId > kMaxSupportedFormatVersion {
            throw SleapIOError.formatVersionTooNew(formatId)
        }
    }

    /// Whether this reader models the ROI/segmentation-mask tables for a given
    /// format version.
    ///
    /// The `rois`/`masks` HDF5 tables are modeled for the 1.5 schema only.
    /// Newer versions (1.6-2.4) may store these annotations under a different
    /// schema this reader does not understand, so the tables are skipped there
    /// (they count among the unmodeled datasets). Versions before 1.5 predate
    /// the tables entirely.
    static func modelsAnnotationTables(formatId: Float) -> Bool {
        formatId >= 1.5 && formatId < 1.6
    }

    /// Read an SLP file and return a Labels object.
    /// This is the eager path — all frames are fully materialized.
    public static func read(from path: String, progress: ProgressReporter? = nil) async throws -> Labels {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SleapIOError.fileNotFound("File not found: \(path)")
        }

        let actor = try HDF5FileActor.openReadOnly(path: path)
        return try await actor.withFile { file in
            try readFromFile(file, progress: progress)
        }
    }

    /// Read from an open HDF5File (internal, for use within module).
    static func readFromFile(_ file: HDF5File, progress: ProgressReporter? = nil) throws -> Labels {
        progress?(0)

        // 1. Read metadata
        let metadataGroup = try file.openGroup(name: "metadata")
        let formatId = try metadataGroup.readFloatAttribute(name: "format_id")

        // Reject only versions strictly newer than the supported cap. Versions
        // 1.6-2.4 load on a best-effort basis, skipping unmodeled datasets.
        try validateFormatVersion(formatId)

        let jsonStr = try metadataGroup.readStringAttribute(name: "json")
        let metadata = try SLPMetadata.parse(json: jsonStr, formatId: formatId)

        let skeletons = metadata.skeletons

        // 2. Read tracks
        let tracks = try readTracks(from: file)

        // 3. Read videos
        let (videos, videoIdMap) = try SLPVideoTable.readVideosAndIdMap(from: file)
        try SLPVideoTable.configureBackends(for: videos, filePath: file.path, formatId: formatId)

        // 4. Read points
        let (pointsX, pointsY, pointsVisible, pointsComplete) = try readPoints(
            from: file, datasetName: "points")

        // 5. Read pred_points
        let (predX, predY, predVisible, predComplete, predScores) = try readPredPoints(from: file)

        // 6. Read instances
        let instanceData = try readInstances(from: file, formatId: formatId)

        // 7. Read frames
        let frameData = try readFrames(from: file)
        try SLPVideoTable.validateReferencedVideoIDs(
            frameData.map(\.video),
            videoIdMap: videoIdMap,
            videoCount: videos.count
        )

        // 8. Build object graph
        let allInstances = try buildInstances(
            instanceData: instanceData,
            pointsX: pointsX, pointsY: pointsY,
            pointsVisible: pointsVisible, pointsComplete: pointsComplete,
            predX: predX, predY: predY,
            predVisible: predVisible, predComplete: predComplete,
            predScores: predScores,
            skeletons: skeletons, tracks: tracks,
            formatId: formatId
        )

        let frames = try buildFrames(
            frameData: frameData,
            allInstances: allInstances,
            videos: videos,
            videoIdMap: videoIdMap,
            progress: progress
        )

        // 9. Resolve from_predicted (second pass)
        resolveFromPredicted(
            allInstances: allInstances,
            instanceData: instanceData
        )

        // 10. Read suggestions
        let suggestions = try readSuggestions(from: file, videos: videos, videoIdMap: videoIdMap)

        // 11. Mark negative frames
        try markNegativeFrames(from: file, frames: frames, videos: videos, videoIdMap: videoIdMap)

        // 12. Read sessions
        let sessions = try readSessions(from: file, videos: videos, videoIdMap: videoIdMap)

        // 13. Read ROIs
        let rois = try readROIs(from: file, formatId: formatId)

        // 14. Read masks
        let masks = try readMasks(from: file, formatId: formatId)

        // Apply pre-1.1 coordinate adjustment
        if formatId < 1.1 {
            applyCoordinateAdjustment(frames: frames)
        }

        let store = EagerFrameStore(frames: frames)
        let labels = Labels(
            frameStore: store,
            videos: videos,
            skeletons: skeletons,
            tracks: tracks,
            suggestions: suggestions,
            sessions: sessions,
            provenance: metadata.provenance,
            rois: rois,
            masks: masks
        )
        progress?(1.0)
        return labels
    }

    // MARK: - Read tracks

    private static func readTracks(from file: HDF5File) throws -> [Track] {
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

    // MARK: - Read points

    private static func readPoints(from file: HDF5File, datasetName: String)
    throws -> (x: ContiguousArray<Double>, y: ContiguousArray<Double>,
               visible: ContiguousArray<Bool>, complete: ContiguousArray<Bool>) {
        guard file.exists(name: datasetName) else {
            return (ContiguousArray(), ContiguousArray(), ContiguousArray(), ContiguousArray())
        }

        let ds = try file.openDataset(name: datasetName)
        let count = ds.count

        let x = try ds.readCompoundFieldFloat64(fieldName: "x", count: count)
        let y = try ds.readCompoundFieldFloat64(fieldName: "y", count: count)
        let visible = try ds.readCompoundFieldBool(fieldName: "visible", count: count)
        let complete = try ds.readCompoundFieldBool(fieldName: "complete", count: count)

        return (x, y, visible, complete)
    }

    // MARK: - Read pred_points

    private static func readPredPoints(from file: HDF5File)
    throws -> (x: ContiguousArray<Double>, y: ContiguousArray<Double>,
               visible: ContiguousArray<Bool>, complete: ContiguousArray<Bool>,
               scores: ContiguousArray<Double>) {
        guard file.exists(name: "pred_points") else {
            return (ContiguousArray(), ContiguousArray(), ContiguousArray(),
                    ContiguousArray(), ContiguousArray())
        }

        let ds = try file.openDataset(name: "pred_points")
        let count = ds.count

        let x = try ds.readCompoundFieldFloat64(fieldName: "x", count: count)
        let y = try ds.readCompoundFieldFloat64(fieldName: "y", count: count)
        let visible = try ds.readCompoundFieldBool(fieldName: "visible", count: count)
        let complete = try ds.readCompoundFieldBool(fieldName: "complete", count: count)
        let scores = try ds.readCompoundFieldFloat64(fieldName: "score", count: count)

        return (x, y, visible, complete, scores)
    }

    // MARK: - Read instances

    struct InstanceRow {
        var instanceType: UInt8
        var skeleton: Int
        var track: Int32
        var fromPredicted: Int64
        var score: Float
        var pointIdStart: UInt64
        var pointIdEnd: UInt64
        var trackingScore: Float
    }

    private static func readInstances(from file: HDF5File, formatId: Float) throws -> [InstanceRow] {
        guard file.exists(name: "instances") else { return [] }
        let ds = try file.openDataset(name: "instances")
        let count = ds.count

        let instanceType = try ds.readCompoundFieldUInt8(fieldName: "instance_type", count: count)
        let skeleton = try ds.readCompoundFieldUInt32(fieldName: "skeleton", count: count)
        let track = try ds.readCompoundFieldInt32(fieldName: "track", count: count)
        let fromPredicted = try ds.readCompoundFieldInt64(fieldName: "from_predicted", count: count)
        let score = try ds.readCompoundFieldFloat32(fieldName: "score", count: count)
        let pointIdStart = try ds.readCompoundFieldUInt64(fieldName: "point_id_start", count: count)
        let pointIdEnd = try ds.readCompoundFieldUInt64(fieldName: "point_id_end", count: count)

        let trackingScore: ContiguousArray<Float>
        if formatId >= 1.2 {
            trackingScore = try ds.readCompoundFieldFloat32(fieldName: "tracking_score", count: count)
        } else {
            trackingScore = ContiguousArray(repeating: 0.0, count: count)
        }

        var rows: [InstanceRow] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            rows.append(InstanceRow(
                instanceType: instanceType[i],
                skeleton: Int(skeleton[i]),
                track: track[i],
                fromPredicted: fromPredicted[i],
                score: score[i],
                pointIdStart: pointIdStart[i],
                pointIdEnd: pointIdEnd[i],
                trackingScore: trackingScore[i]
            ))
        }
        return rows
    }

    // MARK: - Read frames

    struct FrameRow {
        var video: Int
        var frameIdx: Int
        var instanceIdStart: UInt64
        var instanceIdEnd: UInt64
    }

    private static func readFrames(from file: HDF5File) throws -> [FrameRow] {
        guard file.exists(name: "frames") else { return [] }
        let ds = try file.openDataset(name: "frames")
        let count = ds.count

        let video = try ds.readCompoundFieldUInt32(fieldName: "video", count: count)
        let frameIdx = try ds.readCompoundFieldUInt64(fieldName: "frame_idx", count: count)
        let instStart = try ds.readCompoundFieldUInt64(fieldName: "instance_id_start", count: count)
        let instEnd = try ds.readCompoundFieldUInt64(fieldName: "instance_id_end", count: count)

        var rows: [FrameRow] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            rows.append(FrameRow(
                video: Int(video[i]),
                frameIdx: Int(frameIdx[i]),
                instanceIdStart: instStart[i],
                instanceIdEnd: instEnd[i]
            ))
        }
        return rows
    }

    // MARK: - Build instances

    private static func buildInstances(
        instanceData: [InstanceRow],
        pointsX: ContiguousArray<Double>, pointsY: ContiguousArray<Double>,
        pointsVisible: ContiguousArray<Bool>, pointsComplete: ContiguousArray<Bool>,
        predX: ContiguousArray<Double>, predY: ContiguousArray<Double>,
        predVisible: ContiguousArray<Bool>, predComplete: ContiguousArray<Bool>,
        predScores: ContiguousArray<Double>,
        skeletons: [Skeleton], tracks: [Track],
        formatId: Float
    ) throws -> [Instance] {
        var instances: [Instance] = []
        instances.reserveCapacity(instanceData.count)

        for row in instanceData {
            let skelIdx = min(row.skeleton, skeletons.count - 1)
            let skeleton = skeletons[max(0, skelIdx)]

            let track: Track? = row.track >= 0 && Int(row.track) < tracks.count
                ? tracks[Int(row.track)] : nil

            let trackingScore: Float? = row.trackingScore != 0 ? row.trackingScore : nil

            let isUser = row.instanceType == 0
            let start = Int(row.pointIdStart)
            let end = Int(row.pointIdEnd)
            let nodeCount = end - start

            if isUser {
                let pts = makePointsArray(
                    x: pointsX, y: pointsY,
                    visible: pointsVisible, complete: pointsComplete,
                    start: start, count: nodeCount, skeleton: skeleton
                )
                let inst = Instance(skeleton: skeleton, points: pts,
                                    track: track, trackingScore: trackingScore)
                instances.append(inst)
            } else {
                let pts = makePointsArray(
                    x: predX, y: predY,
                    visible: predVisible, complete: predComplete,
                    start: start, count: nodeCount, skeleton: skeleton
                )
                let scores = ContiguousArray<Float>(
                    (start..<end).map { i in
                        i < predScores.count ? Float(predScores[i]) : 0.0
                    }
                )
                let predPts = PredictedPointsArray(pointsArray: pts, scores: scores)
                let inst = PredictedInstance(skeleton: skeleton, points: predPts,
                                            score: row.score, track: track,
                                            trackingScore: trackingScore)
                instances.append(inst)
            }
        }

        return instances
    }

    private static func makePointsArray(
        x: ContiguousArray<Double>, y: ContiguousArray<Double>,
        visible: ContiguousArray<Bool>, complete: ContiguousArray<Bool>,
        start: Int, count: Int, skeleton: Skeleton
    ) -> PointsArray {
        var coords = ContiguousArray<Float>(repeating: 0, count: count * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: count)
        var comp = ContiguousArray<Bool>(repeating: false, count: count)

        for i in 0..<count {
            let srcIdx = start + i
            if srcIdx < x.count {
                coords[i * 2] = Float(x[srcIdx])
                coords[i * 2 + 1] = Float(y[srcIdx])
                vis[i] = visible[srcIdx]
                comp[i] = complete[srcIdx]
            }
        }

        var pts = PointsArray(coordinates: coords, visibility: vis, completeness: comp)
        pts.skeleton = skeleton
        return pts
    }

    // MARK: - Build frames

    private static func buildFrames(
        frameData: [FrameRow],
        allInstances: [Instance],
        videos: [Video],
        videoIdMap: [Int: Int],
        progress: ProgressReporter?
    ) throws -> [LabeledFrame] {
        var frames: [LabeledFrame] = []
        frames.reserveCapacity(frameData.count)

        let total = frameData.count
        for (offset, row) in frameData.enumerated() {
            try Task.checkCancellation()
            if total > 0 {
                progress?(Double(offset) / Double(total))
            }

            guard let videoIdx = SLPVideoTable.resolvedIndex(
                for: row.video,
                videoIdMap: videoIdMap,
                videoCount: videos.count
            ) else {
                continue
            }

            let video = videos[videoIdx]
            let start = Int(row.instanceIdStart)
            let end = min(Int(row.instanceIdEnd), allInstances.count)

            let frameInstances = Array(allInstances[start..<end])
            let frame = LabeledFrame(video: video, frameIndex: row.frameIdx, instances: frameInstances)
            frames.append(frame)
        }

        return frames
    }

    // MARK: - Resolve from_predicted

    private static func resolveFromPredicted(
        allInstances: [Instance],
        instanceData: [InstanceRow]
    ) {
        for (i, row) in instanceData.enumerated() {
            let fromPredIdx = Int(row.fromPredicted)
            guard fromPredIdx >= 0 && fromPredIdx < allInstances.count else { continue }
            if let predicted = allInstances[fromPredIdx] as? PredictedInstance {
                allInstances[i].fromPredicted = predicted
            }
        }
    }

    // MARK: - Read suggestions

    private static func readSuggestions(
        from file: HDF5File, videos: [Video], videoIdMap: [Int: Int]
    ) throws -> [SuggestionFrame] {
        guard file.exists(name: "suggestions_json") else { return [] }
        let ds = try file.openDataset(name: "suggestions_json")
        let strings = try ds.readVLenStrings()

        var suggestions: [SuggestionFrame] = []
        for str in strings {
            guard let data = str.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
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

            suggestions.append(SuggestionFrame(
                video: videos[resolvedIdx],
                frameIndex: frameIdx,
                group: group
            ))
        }
        return suggestions
    }

    // MARK: - Mark negative frames

    private static func markNegativeFrames(
        from file: HDF5File, frames: [LabeledFrame],
        videos: [Video], videoIdMap: [Int: Int]
    ) throws {
        guard file.exists(name: "negative_frames") else { return }
        let ds = try file.openDataset(name: "negative_frames")
        let count = ds.count
        guard count > 0 else { return }

        let videoIds = try ds.readCompoundFieldUInt32(fieldName: "video_id", count: count)
        let frameIdxs = try ds.readCompoundFieldUInt64(fieldName: "frame_idx", count: count)

        // Build lookup set
        var negativeSet = Set<String>()
        for i in 0..<count {
            guard let vidIdx = SLPVideoTable.resolvedIndex(
                for: Int(videoIds[i]),
                videoIdMap: videoIdMap,
                videoCount: videos.count
            ) else {
                continue
            }
            negativeSet.insert("\(vidIdx)_\(frameIdxs[i])")
        }

        for frame in frames {
            if let vidIdx = videos.firstIndex(where: { $0 === frame.video }) {
                if negativeSet.contains("\(vidIdx)_\(frame.frameIndex)") {
                    frame.isNegative = true
                }
            }
        }
    }

    // MARK: - Read sessions

    private static func readSessions(
        from file: HDF5File, videos: [Video], videoIdMap: [Int: Int]
    ) throws -> [RecordingSession] {
        guard file.exists(name: "sessions_json") else { return [] }
        let ds = try file.openDataset(name: "sessions_json")
        let strings = try ds.readVLenStrings()

        var sessions: [RecordingSession] = []
        for str in strings {
            guard let data = str.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // Basic session parsing — cameras and video mapping
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

    // MARK: - Read ROIs

    static func readROIs(from file: HDF5File, formatId: Float) throws -> [ROI] {
        // Gate on dataset presence, not format version: Python writes /rois ungated
        // and its dtype is a superset of the fields we read by name, so 1.6-2.4 files
        // carrying ROIs must not be silently dropped. (1.5 behavior unchanged.)
        guard file.exists(name: "rois") else { return [] }

        do {
            let ds = try file.openDataset(name: "rois")
            let count = ds.count
            guard count > 0 else { return [] }

            let annotationType = try ds.readCompoundFieldUInt8(fieldName: "annotation_type", count: count)
            let video = try ds.readCompoundFieldInt32(fieldName: "video", count: count)
            let frameIdx = try ds.readCompoundFieldInt64(fieldName: "frame_idx", count: count)
            let track = try ds.readCompoundFieldInt32(fieldName: "track", count: count)
            let score = try ds.readCompoundFieldFloat32(fieldName: "score", count: count)
            let wkbStart = try ds.readCompoundFieldUInt64(fieldName: "wkb_start", count: count)
            let wkbEnd = try ds.readCompoundFieldUInt64(fieldName: "wkb_end", count: count)

            // Read ROI metadata attributes
            let categories = try readJSONListAttribute(from: ds, name: "categories", count: count)
            let names = try readJSONListAttribute(from: ds, name: "names", count: count)
            let sources = try readJSONListAttribute(from: ds, name: "sources", count: count)

            // Read WKB geometry
            let wkbData: [UInt8]
            if file.exists(name: "roi_wkb") {
                let wkbDs = try file.openDataset(name: "roi_wkb")
                wkbData = try wkbDs.readUInt8()
            } else {
                wkbData = []
            }

            var rois: [ROI] = []
            for i in 0..<count {
                let atypeRaw = annotationType[i]
                let atype = decodeAnnotationType(atypeRaw)

                let start = Int(wkbStart[i])
                let end = Int(wkbEnd[i])
                let points = parseWKBGeometry(Array(wkbData[start..<min(end, wkbData.count)]))

                var roi = ROI(annotationType: atype, name: names[i], points: points)
                roi.category = categories[i].isEmpty ? nil : categories[i]
                roi.score = score[i]
                roi.source = sources[i].isEmpty ? nil : sources[i]
                roi.videoIndex = Int(video[i])
                roi.frameIndex = Int(frameIdx[i])
                roi.trackIndex = track[i] >= 0 ? Int(track[i]) : nil
                rois.append(roi)
            }

            return rois
        } catch {
            // 1.5 is fully modeled — surface real read errors. For 1.6+ the schema may be
            // extended/unknown; skip gracefully rather than failing the whole load.
            if SLPReader.modelsAnnotationTables(formatId: formatId) { throw error }
            return []
        }
    }

    // MARK: - Read masks

    static func readMasks(from file: HDF5File, formatId: Float) throws -> [SegmentationMask] {
        // Gate on dataset presence, not format version (see readROIs): 1.6-2.4 files
        // carrying /masks must not be silently dropped.
        guard file.exists(name: "masks") else { return [] }

        do {
            let ds = try file.openDataset(name: "masks")
            let count = ds.count
            guard count > 0 else { return [] }

            let height = try ds.readCompoundFieldUInt32(fieldName: "height", count: count)
            let width = try ds.readCompoundFieldUInt32(fieldName: "width", count: count)
            let annotationType = try ds.readCompoundFieldUInt8(fieldName: "annotation_type", count: count)
            let video = try ds.readCompoundFieldInt32(fieldName: "video", count: count)
            let frameIdx = try ds.readCompoundFieldInt64(fieldName: "frame_idx", count: count)
            let track = try ds.readCompoundFieldInt32(fieldName: "track", count: count)
            let score = try ds.readCompoundFieldFloat32(fieldName: "score", count: count)
            let rleStart = try ds.readCompoundFieldUInt64(fieldName: "rle_start", count: count)
            let rleEnd = try ds.readCompoundFieldUInt64(fieldName: "rle_end", count: count)

            let names = try readJSONListAttribute(from: ds, name: "names", count: count)
            let categories = try readJSONListAttribute(from: ds, name: "categories", count: count)
            let sources = try readJSONListAttribute(from: ds, name: "sources", count: count)

            // Read RLE data
            let rleData: [UInt8]
            if file.exists(name: "mask_rle") {
                let rleDs = try file.openDataset(name: "mask_rle")
                rleData = try rleDs.readUInt8()
            } else {
                rleData = []
            }

            var masks: [SegmentationMask] = []
            for i in 0..<count {
                let start = Int(rleStart[i])
                let end = Int(rleEnd[i])
                let rleBytes = Array(rleData[start..<min(end, rleData.count)])

                // Decode uint32 RLE counts from packed bytes
                let rleCounts = decodeRLECounts(from: rleBytes)

                var mask = SegmentationMask(
                    rleCounts: rleCounts,
                    height: Int(height[i]),
                    width: Int(width[i]),
                    name: names[i]
                )
                mask.annotationType = decodeAnnotationType(annotationType[i])
                mask.category = categories[i].isEmpty ? nil : categories[i]
                mask.score = score[i]
                mask.source = sources[i].isEmpty ? nil : sources[i]
                mask.videoIndex = Int(video[i])
                mask.frameIndex = Int(frameIdx[i])
                mask.trackIndex = track[i] >= 0 ? Int(track[i]) : nil
                masks.append(mask)
            }

            return masks
        } catch {
            // 1.5 is fully modeled — surface real read errors. For 1.6+ the schema may be
            // extended/unknown; skip gracefully rather than failing the whole load.
            if SLPReader.modelsAnnotationTables(formatId: formatId) { throw error }
            return []
        }
    }

    // MARK: - Helpers

    private static func readJSONListAttribute(from ds: HDF5Dataset, name: String, count: Int) throws -> [String] {
        guard ds.hasAttribute(name: name) else {
            return Array(repeating: "", count: count)
        }
        let jsonStr = try ds.readStringAttribute(name: name)
        guard let data = jsonStr.data(using: .utf8),
              let arr = try JSONSerialization.jsonObject(with: data) as? [String] else {
            return Array(repeating: "", count: count)
        }
        if arr.count >= count {
            return Array(arr.prefix(count))
        }
        return arr + Array(repeating: "", count: count - arr.count)
    }

    private static func decodeAnnotationType(_ raw: UInt8) -> AnnotationType {
        switch raw {
        case 0: return .boundingBox
        case 1: return .polygon
        case 2: return .polyline
        case 3: return .point
        case 4: return .ellipse
        case 5: return .segmentationMask
        default: return .boundingBox
        }
    }

    private static func parseWKBGeometry(_ bytes: [UInt8]) -> [SIMD2<Float>] {
        // Simplified WKB parsing — extract coordinate pairs
        guard bytes.count >= 5 else { return [] }

        // WKB format: byte_order (1), geometry_type (4), then coords
        // We do a basic extraction of float64 coordinate pairs
        var points: [SIMD2<Float>] = []
        var offset = 5 // Skip byte order + geometry type

        // Check geometry type (use safe unaligned read)
        let geomType = readUInt32(from: bytes, at: 1)

        switch geomType {
        case 1: // Point
            if offset + 16 <= bytes.count {
                let x = readDouble(from: bytes, at: offset)
                let y = readDouble(from: bytes, at: offset + 8)
                points.append(SIMD2(Float(x), Float(y)))
            }
        case 2, 3: // LineString or Polygon
            if offset + 4 <= bytes.count {
                if geomType == 3 {
                    // Polygon has a ring count first
                    offset += 4
                }
                if offset + 4 <= bytes.count {
                    let numPoints = readUInt32(from: bytes, at: offset)
                    offset += 4
                    for _ in 0..<numPoints {
                        if offset + 16 <= bytes.count {
                            let x = readDouble(from: bytes, at: offset)
                            let y = readDouble(from: bytes, at: offset + 8)
                            points.append(SIMD2(Float(x), Float(y)))
                            offset += 16
                        }
                    }
                }
            }
        default:
            break
        }

        return points
    }

    private static func readDouble(from bytes: [UInt8], at offset: Int) -> Double {
        var value: Double = 0
        withUnsafeMutableBytes(of: &value) { dst in
            bytes.withUnsafeBufferPointer { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress! + offset, count: 8))
            }
        }
        return value
    }

    private static func readUInt32(from bytes: [UInt8], at offset: Int) -> Int {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
            bytes.withUnsafeBufferPointer { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress! + offset, count: 4))
            }
        }
        return Int(value)
    }

    private static func decodeRLECounts(from bytes: [UInt8]) -> [Int] {
        // RLE counts are packed as uint32 little-endian
        var counts: [Int] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            var val: UInt32 = 0
            withUnsafeMutableBytes(of: &val) { dst in
                bytes.withUnsafeBufferPointer { src in
                    dst.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress! + offset, count: 4))
                }
            }
            counts.append(Int(val))
            offset += 4
        }
        return counts
    }

    // MARK: - Pre-1.1 coordinate adjustment

    private static func applyCoordinateAdjustment(frames: [LabeledFrame]) {
        for frame in frames {
            for instance in frame.instances {
                for i in 0..<instance.points.count {
                    instance.points.coordinates[i * 2] -= 0.5
                    instance.points.coordinates[i * 2 + 1] -= 0.5
                }
            }
        }
    }
}

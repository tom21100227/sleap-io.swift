import Foundation
import CHDF5
import SleapIO
import SleapVideo

/// Writes SLEAP .slp files (HDF5-based).
public struct SLPWriter {

    /// Write a Labels object to an SLP file.
    ///
    /// When the destination path matches a source file used by embedded videos,
    /// writes to a temporary file first, then atomically replaces the original.
    ///
    /// - Parameters:
    ///   - embed: Which frames, if any, to embed as image data in the saved file
    ///     (mirrors Python sleap-io's `embed=`). Defaults to ``EmbedSelection/none``,
    ///     which leaves the writer's behavior unchanged: external videos stay
    ///     referenced by path and already-embedded videos are preserved verbatim.
    ///     When a selection embeds frames, they are decoded via the video backends
    ///     and re-encoded with `imageFormat` into per-video `/videoN` groups, each
    ///     carrying a `source_video` lineage back to the original video.
    ///   - imageFormat: The image format used when re-encoding embedded frames.
    ///     Reuses ``SleapIO/SaveOptions/EmbeddedImageFormat``; defaults to `.png`
    ///     (lossless), matching Python's embed default. Ignored when not embedding.
    public static func write(
        _ labels: Labels,
        to path: String,
        embed: EmbedSelection = .none,
        imageFormat: SaveOptions.EmbeddedImageFormat = .png,
        progress: ProgressReporter? = nil
    ) async throws {
        progress?(0)
        try Task.checkCancellation()

        // Decode + re-encode the frames selected for embedding *before* opening
        // the destination file: frame decoding is async and cannot run inside the
        // synchronous HDF5 write closure. `embed == .none` returns an empty plan
        // without touching the video backends or the progress reporter, so the
        // non-embedding path is byte-for-byte the historical behavior.
        let embedProgress: ProgressReporter? = progress.map { p in { p(0.4 * $0) } }
        let plan = try await EmbedPipeline.buildPlan(
            labels: labels, embed: embed, imageFormat: imageFormat, progress: embedProgress)

        // When frames were embedded, reserve the first 40% of the progress budget
        // for the decode/encode phase and scale the file-write phase into the
        // remaining 60%, keeping the reported fraction monotonic. Otherwise the
        // file-write phase drives progress directly (unchanged).
        let didEmbedFrames = !plan.videos.isEmpty
        let writeProgress: ProgressReporter?
        if didEmbedFrames, let p = progress {
            writeProgress = { p(0.4 + 0.6 * $0) }
        } else {
            writeProgress = progress
        }

        // Check if any embedded video's source is the same as the destination.
        let needsAtomicReplace = labels.videos.contains { video in
            guard let backend = video.backend as? SleapHDF5EmbeddedVideoBackend,
                  let sourcePath = backend.sourceFilePath else { return false }
            return resolvePath(sourcePath) == resolvePath(path)
        }

        if needsAtomicReplace {
            // Write to a temp file, then atomically replace the destination.
            let tempPath = path + ".sleap-tmp-\(UUID().uuidString)"
            let actor = try HDF5FileActor.create(path: tempPath)
            try await actor.withFile { file in
                try writeToFile(labels, file: file, embedPlan: plan, progress: writeProgress)
            }
            // Close source HDF5 handles by letting the actor deinit,
            // then atomically replace.
            try Task.checkCancellation()
            let fm = FileManager.default
            _ = try fm.replaceItemAt(URL(fileURLWithPath: path),
                                     withItemAt: URL(fileURLWithPath: tempPath))
        } else {
            let actor = try HDF5FileActor.create(path: path)
            try await actor.withFile { file in
                try writeToFile(labels, file: file, embedPlan: plan, progress: writeProgress)
            }
        }
        progress?(1.0)
    }

    /// Resolve a path to a canonical absolute path for comparison.
    private static func resolvePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Write to an open HDF5File (internal).
    ///
    /// - Parameter embedPlan: The resolved embed plan from ``EmbedPipeline``, or
    ///   `nil`/empty for a plain save. Videos in ``EmbedPlan/videos`` are written
    ///   as embedded `/videoN` groups (with a self-referencing `source_video`
    ///   lineage); videos in ``EmbedPlan/restoreOriginal`` are rewritten to point
    ///   at their source video instead of an embedded dataset.
    static func writeToFile(_ labels: Labels, file: HDF5File, embedPlan: EmbedPlan? = nil, progress: ProgressReporter? = nil) throws {
        let hasROIs = !labels.rois.isEmpty
        let hasMasks = !labels.masks.isEmpty
        let hasBboxes = !labels.bboxes.isEmpty
        let hasCentroids = !labels.centroids.isEmpty
        let hasIdentities = !labels.identities.isEmpty
        let hasLabelImages = !labels.labelImages.isEmpty

        // Stamp the minimum format version that can represent this data
        // (downgrade-on-save), so the oldest compatible SLEAP can still open it.
        var formatId = minimumFormatId(for: labels)
        // Newly embedded videos carry the `channel_order` attribute (format 1.4),
        // even when the in-memory videos are still external (media) backends.
        if !(embedPlan?.videos.isEmpty ?? true) {
            formatId = max(formatId, 1.4)
        }

        // 1. Write metadata
        try writeMetadata(labels, file: file, formatId: formatId)

        // 2. Write tracks
        try writeTracks(labels.tracks, file: file)

        // 3. Write videos
        try writeVideos(labels.videos, file: file, embedPlan: embedPlan)
        try writeEmbeddedVideos(labels.videos, file: file, embedPlan: embedPlan, progress: progress)

        // 4. Collect and write compound datasets
        try writeCompoundData(labels, file: file, progress: progress)

        // 5. Write negative frames
        try writeNegativeFrames(labels, file: file)

        // 6. Write suggestions
        try writeSuggestions(labels, file: file)

        // 7. Write sessions
        try writeSessions(labels, file: file)

        // 8. Write ROIs
        if hasROIs {
            try writeROIs(labels.rois, file: file)
        }

        // 9. Write masks
        if hasMasks {
            try writeMasks(labels.masks, file: file)
        }

        // 10. Write identities
        if hasIdentities {
            try writeIdentities(labels.identities, file: file)
        }

        // 11. Write bounding boxes
        if hasBboxes {
            try writeBboxes(labels.bboxes, file: file)
        }

        // 12. Write centroids
        if hasCentroids {
            try writeCentroids(labels.centroids, file: file)
        }

        // 13. Write label images
        if hasLabelImages {
            try writeLabelImages(labels.labelImages, file: file)
        }
    }

    // MARK: - Write-version migration

    /// Choose the minimum SLP `format_id` that faithfully represents `labels`,
    /// mirroring Python sleap-io's downgrade-on-save. Rather than a single
    /// hard-coded version, each feature contributes a floor and the file is
    /// stamped with the highest floor among the features actually present, so the
    /// output stays readable by the oldest SLEAP that understands those features.
    ///
    /// Floors (Python's format-version history plus the Swift port's extensions):
    ///   - **1.2** (base): the writer always emits center-origin coordinates
    ///     (1.1) and the `tracking_score` field on `/instances` (1.2), so a
    ///     points-only file downgrades to 1.2.
    ///   - **1.4**: embedded (HDF5) video datasets carry the `channel_order`
    ///     attribute.
    ///   - **1.5**: `/rois` or `/masks` tables are present.
    ///   - **1.7**: `/bboxes` or `/centroids` tables are present (Swift port
    ///     extension; centroids have no Python analog and follow bboxes).
    ///   - **1.8**: `/label_images` are present (Python added the label-image
    ///     datasets at format 1.8).
    ///   - **1.9**: `/identities_json` is present (Swift port extension).
    static func minimumFormatId(for labels: Labels) -> Float {
        var formatId: Float = 1.2
        if labels.hasEmbeddedVideo { formatId = max(formatId, 1.4) }
        if !labels.rois.isEmpty || !labels.masks.isEmpty { formatId = max(formatId, 1.5) }
        if !labels.bboxes.isEmpty || !labels.centroids.isEmpty { formatId = max(formatId, 1.7) }
        if !labels.labelImages.isEmpty { formatId = max(formatId, 1.8) }
        if !labels.identities.isEmpty { formatId = max(formatId, 1.9) }
        return formatId
    }

    // MARK: - Write metadata

    private static func writeMetadata(_ labels: Labels, file: HDF5File, formatId: Float) throws {
        let metaGroup = try file.createGroup(name: "metadata")
        try metaGroup.writeFloatAttribute(name: "format_id", value: formatId)

        // Build metadata JSON with skeletons and provenance
        var metaDict: [String: Any] = [:]
        metaDict["version"] = "2.0.0"
        // Bridge JSONValue provenance to Foundation objects so JSONSerialization can
        // emit arbitrary JSON (numbers, booleans, nested containers) intact.
        metaDict["provenance"] = labels.provenance.mapValues { $0.jsonObject }

        // Encode skeletons
        var skelList: [[String: Any]] = []
        for skeleton in labels.skeletons {
            skelList.append(SkeletonCodec.encodeToNetworkX(skeleton))
        }
        metaDict["skeletons"] = skelList

        // Superset node list
        var nodesList: [[String: Any]] = []
        for skeleton in labels.skeletons {
            for node in skeleton.nodes {
                nodesList.append(["py/state": ["name": node.name, "weight": 1.0]])
            }
        }
        metaDict["nodes"] = nodesList

        let jsonData = try JSONSerialization.data(withJSONObject: metaDict, options: [.sortedKeys])
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
        try metaGroup.writeStringAttribute(name: "json", value: jsonStr)
    }

    // MARK: - Write tracks

    private static func writeTracks(_ tracks: [Track], file: HDF5File) throws {
        guard !tracks.isEmpty else { return }
        var trackJsons: [String] = []
        for (i, track) in tracks.enumerated() {
            let arr: [Any] = [i, track.name]
            let data = try JSONSerialization.data(withJSONObject: arr)
            trackJsons.append(String(data: data, encoding: .utf8) ?? "")
        }
        try file.writeVLenStringDataset(name: "tracks_json", strings: trackJsons)
    }

    // MARK: - Write videos

    private static func writeVideos(_ videos: [Video], file: HDF5File, embedPlan: EmbedPlan? = nil) throws {
        guard !videos.isEmpty else { return }
        var videoJsons: [String] = []
        for (index, video) in videos.enumerated() {
            let dict: [String: Any]
            if let plan = embedPlan?.videos[index] {
                // Video is being embedded on this save: describe the embedded HDF5
                // backend and nest the original (external) video as `source_video`.
                dict = embeddedVideoJSON(videoIndex: index, plan: plan, video: video)
            } else if embedPlan?.restoreOriginal.contains(index) == true,
                      let source = video.sourceVideo {
                // embed = .source: restore the original external video reference,
                // dropping the embedded dataset entirely.
                dict = encodeVideo(source)
            } else {
                dict = encodeVideo(video)
            }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            videoJsons.append(String(data: data, encoding: .utf8) ?? "")
        }
        try file.writeVLenStringDataset(name: "videos_json", strings: videoJsons)
    }

    /// Build the `videos_json` entry for a freshly embedded video: an
    /// `HDF5Video`-style backend pointing at this file's `/videoN/video` dataset,
    /// with the pre-embedding (external) video nested under `source_video`.
    ///
    /// `filename` is `"."` (the Python convention for "this container") and `type`
    /// is `"HDF5Video"`, both of which route the reader to the embedded backend.
    /// The nested `source_video` mirrors what is also written into the
    /// `/videoN/source_video` HDF5 group, so lineage survives a round-trip whether
    /// it is read inline or recovered from the group.
    private static func embeddedVideoJSON(videoIndex: Int, plan: EmbeddedVideoPlan, video: Video) -> [String: Any] {
        let backend: [String: Any] = [
            "filename": ".",
            "type": "HDF5Video",
            "dataset": "video\(videoIndex)/video",
            "format": plan.format,
            "channel_order": plan.channelOrder,
            "shape": [plan.frames.count, plan.height, plan.width, plan.channels],
        ]
        var dict: [String: Any] = ["backend": backend]
        // The video as it stands (external source) becomes this embedded video's
        // source; `encodeVideo` recursively preserves any deeper source chain.
        dict["source_video"] = encodeVideo(video)
        return dict
    }

    /// Encode a ``Video`` to its Python-compatible `videos_json` dictionary — the
    /// inverse of ``SLPVideoTable/decodeVideo(from:)`` and a mirror of Python
    /// sleap-io's `video_to_dict`.
    ///
    /// Emits `{ "backend": {...} }` and, when the video carries
    /// ``Video/sourceVideo`` lineage, a nested `source_video` entry so that
    /// provenance survives a save. This is the fix for issue #54: previously the
    /// writer dropped `source_video` for non-embedded videos, silently losing the
    /// lineage on round-trip. The nesting is recursive, so a multi-level source
    /// chain is fully serialized.
    static func encodeVideo(_ video: Video) -> [String: Any] {
        var backend: [String: Any] = video.backendMetadata
        backend["filename"] = video.filename
        backend["type"] = video.backendType

        // Preserve original path provenance only while a permanent relocation is active.
        if video.persistedFilename != nil {
            backend["original_filename"] = video.originalFilename
        } else {
            backend.removeValue(forKey: "original_filename")
        }

        // Persist shape if available but not already in metadata.
        if backend["shape"] == nil,
           let fc = video.frameCount,
           let fs = video.frameSize {
            backend["shape"] = [fc, fs.height, fs.width, fs.channels]
        }

        var dict: [String: Any] = ["backend": backend]
        if let source = video.sourceVideo {
            dict["source_video"] = encodeVideo(source)
        }
        return dict
    }

    /// JSON-encode a ``Video``'s source-video lineage for the embedded
    /// `source_video` HDF5 group, or `nil` when there is no lineage. Mirrors the
    /// nested dictionary ``SLPVideoTable/decodeVideo(fromJSON:)`` decodes.
    private static func sourceVideoJSON(for video: Video) -> String? {
        guard let source = video.sourceVideo,
              let data = try? JSONSerialization.data(
                withJSONObject: encodeVideo(source), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func writeEmbeddedVideos(_ videos: [Video], file: HDF5File, embedPlan: EmbedPlan? = nil, progress: ProgressReporter?) throws {
        for (index, video) in videos.enumerated() {
            // Freshly embedded videos: write the decoded/re-encoded frames from
            // the plan into a new `/videoN` group with source_video lineage.
            if let plan = embedPlan?.videos[index] {
                try Task.checkCancellation()
                try EmbeddedVideo.writeFrames(
                    frameData: plan.frames,
                    videoIndex: index,
                    sourceVideoJSON: plan.sourceVideoJSON,
                    format: plan.format,
                    channelOrder: plan.channelOrder,
                    to: file
                )
                continue
            }

            // embed = .source: the video was rewritten to reference its source
            // video (see `writeVideos`), so no embedded group is written here.
            if embedPlan?.restoreOriginal.contains(index) == true { continue }

            guard video.backendType.lowercased().hasPrefix("hdf5") else { continue }
            guard let backend = video.backend as? SleapHDF5EmbeddedVideoBackend else { continue }

            // Try H5Ocopy from the source file (preserves all frame data without loading into memory).
            if let sourcePath = backend.sourceFilePath,
               let sourceIndex = backend.sourceVideoIndex,
               FileManager.default.fileExists(atPath: sourcePath) {
                let sourceFile = try HDF5File.openReadOnly(path: sourcePath)
                let sourceGroupName = "video\(sourceIndex)"
                let destGroupName = "video\(index)"
                try file.copyObject(from: sourceFile, sourceName: sourceGroupName, destName: destGroupName)
                continue
            }

            // Fallback: write from in-memory cache (degraded mode).
            let frameIndices = backend.embeddedFrames.keys.sorted()
            var frameData: [(sourceFrameIdx: Int, data: Data)] = []
            frameData.reserveCapacity(frameIndices.count)
            for (offset, frameIndex) in frameIndices.enumerated() {
                // Safe cancellation point: embedded frames are still staged in memory.
                try Task.checkCancellation()
                progress?(0.05 * Double(offset) / Double(frameIndices.count))
                if let data = backend.embeddedFrames[frameIndex] {
                    frameData.append((sourceFrameIdx: frameIndex, data: data))
                }
            }

            // Prefer the backend's recorded source-video JSON, but synthesize it
            // from ``Video/sourceVideo`` when the backend carries none (issue #54:
            // an embedded video written from an in-memory cache would otherwise
            // lose its lineage). The H5Ocopy path above already preserves the
            // source_video group verbatim, so this only covers the fallback.
            let backendJSON = backend.sourceVideoJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveSourceVideoJSON: String
            if backendJSON.isEmpty || backendJSON == "{}",
               let synthesized = sourceVideoJSON(for: video) {
                effectiveSourceVideoJSON = synthesized
            } else {
                effectiveSourceVideoJSON = backend.sourceVideoJSON
            }

            try EmbeddedVideo.writeFrames(
                frameData: frameData,
                videoIndex: index,
                sourceVideoJSON: effectiveSourceVideoJSON,
                format: backend.format,
                channelOrder: backend.channelOrder,
                to: file
            )
        }
    }

    // MARK: - Write compound datasets (frames, instances, points, pred_points)

    private static func writeCompoundData(_ labels: Labels, file: HDF5File, progress: ProgressReporter?) throws {
        // Build index maps
        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }
        var skelIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, s) in labels.skeletons.enumerated() { skelIndexMap[ObjectIdentifier(s)] = i }
        var trackIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, t) in labels.tracks.enumerated() { trackIndexMap[ObjectIdentifier(t)] = i }

        // Collect all data
        var frameRows: [(video: UInt32, frameIdx: UInt64, instStart: UInt64, instEnd: UInt64)] = []
        var instanceRows: [(instanceType: UInt8, skeleton: UInt32, track: Int32,
                           fromPredicted: Int64, score: Float,
                           pointStart: UInt64, pointEnd: UInt64, trackingScore: Float)] = []
        var userPoints: [(x: Double, y: Double, visible: Bool, complete: Bool)] = []
        var predPoints: [(x: Double, y: Double, visible: Bool, complete: Bool, score: Double)] = []

        // Build global instance-to-index map for from_predicted resolution
        var instanceIndexMap: [ObjectIdentifier: Int] = [:]
        var globalInstanceIdx = 0

        for i in 0..<labels.frameStore.count {
            // Safe cancellation point: compound rows are still staged in memory.
            try Task.checkCancellation()
            progress?(0.05 + 0.45 * Double(i) / Double(labels.frameStore.count))

            let frame = labels.frameStore.frame(at: i)
            for inst in frame.instances {
                instanceIndexMap[ObjectIdentifier(inst)] = globalInstanceIdx
                globalInstanceIdx += 1
            }
        }

        var instanceIdx = 0
        for i in 0..<labels.frameStore.count {
            // Safe cancellation point: compound rows are still staged in memory.
            try Task.checkCancellation()
            progress?(0.50 + 0.45 * Double(i) / Double(labels.frameStore.count))

            let frame = labels.frameStore.frame(at: i)
            let videoIdx = videoIndexMap[ObjectIdentifier(frame.video)] ?? 0
            let instStart = instanceIdx

            for inst in frame.instances {
                let skelIdx = skelIndexMap[ObjectIdentifier(inst.skeleton)] ?? 0
                let trackIdx: Int32 = inst.track.flatMap { trackIndexMap[ObjectIdentifier($0)] }.map { Int32($0) } ?? -1
                let fromPredIdx: Int64 = inst.fromPredicted.flatMap { instanceIndexMap[ObjectIdentifier($0)] }.map { Int64($0) } ?? -1

                let isPredicted = inst is PredictedInstance
                let score: Float = (inst as? PredictedInstance)?.score ?? 0.0
                let trackingScore: Float = inst.trackingScore ?? 0.0

                if isPredicted {
                    let predStart = predPoints.count
                    for j in 0..<inst.points.count {
                        let predInst = inst as! PredictedInstance
                        predPoints.append((
                            x: Double(inst.points.coordinates[j * 2]),
                            y: Double(inst.points.coordinates[j * 2 + 1]),
                            visible: inst.points.visibility[j],
                            complete: inst.points.completeness[j],
                            score: Double(predInst.predictedPoints.scores[j])
                        ))
                    }
                    instanceRows.append((
                        instanceType: 1, skeleton: UInt32(skelIdx), track: trackIdx,
                        fromPredicted: fromPredIdx, score: score,
                        pointStart: UInt64(predStart), pointEnd: UInt64(predPoints.count),
                        trackingScore: trackingScore
                    ))
                } else {
                    let pointStart = userPoints.count
                    for j in 0..<inst.points.count {
                        userPoints.append((
                            x: Double(inst.points.coordinates[j * 2]),
                            y: Double(inst.points.coordinates[j * 2 + 1]),
                            visible: inst.points.visibility[j],
                            complete: inst.points.completeness[j]
                        ))
                    }
                    instanceRows.append((
                        instanceType: 0, skeleton: UInt32(skelIdx), track: trackIdx,
                        fromPredicted: fromPredIdx, score: score,
                        pointStart: UInt64(pointStart), pointEnd: UInt64(userPoints.count),
                        trackingScore: trackingScore
                    ))
                }

                instanceIdx += 1
            }

            frameRows.append((
                video: UInt32(videoIdx),
                frameIdx: UInt64(frame.frameIndex),
                instStart: UInt64(instStart),
                instEnd: UInt64(instanceIdx)
            ))
        }

        // Write /frames compound dataset
        try writeFramesDataset(frameRows, file: file)

        // Write /instances compound dataset
        try writeInstancesDataset(instanceRows, file: file)

        // Write /points compound dataset
        try writePointsDataset(userPoints, file: file, name: "points")

        // Write /pred_points compound dataset
        try writePredPointsDataset(predPoints, file: file)
    }

    private static func writeFramesDataset(
        _ rows: [(video: UInt32, frameIdx: UInt64, instStart: UInt64, instEnd: UInt64)],
        file: HDF5File
    ) throws {
        guard !rows.isEmpty else { return }

        // Build column arrays
        let frameIds = rows.enumerated().map { UInt64($0.offset) }
        let videos = rows.map { $0.video }
        let frameIdxs = rows.map { $0.frameIdx }
        let instStarts = rows.map { $0.instStart }
        let instEnds = rows.map { $0.instEnd }

        // The compound type size must match the packed row width used below.
        let compSize = 36
        let compType = try HDF5Datatype.createCompound(size: compSize)
        try compType.insertField(name: "frame_id", offset: 0, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "video", offset: 8, type: shim_H5T_NATIVE_UINT32())
        try compType.insertField(name: "frame_idx", offset: 12, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "instance_id_start", offset: 20, type: shim_H5T_NATIVE_UINT64())
        try compType.insertField(name: "instance_id_end", offset: 28, type: shim_H5T_NATIVE_UINT64())

        // Pack into struct-of-arrays → interleaved compound rows
        let rowSize = 36 // actual struct size with alignment
        var buffer = Data(count: rows.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for i in 0..<rows.count {
                let row = base + i * rowSize
                row.storeBytes(of: frameIds[i], toByteOffset: 0, as: UInt64.self)
                row.storeBytes(of: videos[i], toByteOffset: 8, as: UInt32.self)
                row.storeBytes(of: frameIdxs[i], toByteOffset: 12, as: UInt64.self)
                row.storeBytes(of: instStarts[i], toByteOffset: 20, as: UInt64.self)
                row.storeBytes(of: instEnds[i], toByteOffset: 28, as: UInt64.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [rows.count])
        let ds = try file.createDataset(name: "frames", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
    }

    private static func writeInstancesDataset(
        _ rows: [(instanceType: UInt8, skeleton: UInt32, track: Int32,
                  fromPredicted: Int64, score: Float,
                  pointStart: UInt64, pointEnd: UInt64, trackingScore: Float)],
        file: HDF5File
    ) throws {
        guard !rows.isEmpty else { return }

        // Create compound type — 10 fields (format >= 1.2)
        // Layout: id(i8), type(u1), frame_id(u8), skeleton(u4), track(i4),
        //         from_predicted(i8), score(f4), point_start(u8), point_end(u8), tracking_score(f4)
        var offset = 0
        let compType = try HDF5Datatype.createCompound(size: 57)
        try compType.insertField(name: "instance_id", offset: offset, type: shim_H5T_NATIVE_INT64()); offset += 8
        try compType.insertField(name: "instance_type", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        // pad to 8
        offset = 9
        try compType.insertField(name: "frame_id", offset: offset, type: shim_H5T_NATIVE_UINT64()); offset += 8
        offset = 17
        try compType.insertField(name: "skeleton", offset: offset, type: shim_H5T_NATIVE_UINT32()); offset += 4
        offset = 21
        try compType.insertField(name: "track", offset: offset, type: shim_H5T_NATIVE_INT32()); offset += 4
        offset = 25
        try compType.insertField(name: "from_predicted", offset: offset, type: shim_H5T_NATIVE_INT64()); offset += 8
        offset = 33
        try compType.insertField(name: "score", offset: offset, type: shim_H5T_NATIVE_FLOAT()); offset += 4
        offset = 37
        try compType.insertField(name: "point_id_start", offset: offset, type: shim_H5T_NATIVE_UINT64()); offset += 8
        offset = 45
        try compType.insertField(name: "point_id_end", offset: offset, type: shim_H5T_NATIVE_UINT64()); offset += 8
        offset = 53
        try compType.insertField(name: "tracking_score", offset: offset, type: shim_H5T_NATIVE_FLOAT()); offset += 4
        let rowSize = 57

        var buffer = Data(count: rows.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, row) in rows.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: Int64(i), toByteOffset: 0, as: Int64.self) // instance_id
                p.storeBytes(of: row.instanceType, toByteOffset: 8, as: UInt8.self)
                p.storeBytes(of: UInt64(0), toByteOffset: 9, as: UInt64.self) // frame_id (filled separately)
                p.storeBytes(of: row.skeleton, toByteOffset: 17, as: UInt32.self)
                p.storeBytes(of: row.track, toByteOffset: 21, as: Int32.self)
                p.storeBytes(of: row.fromPredicted, toByteOffset: 25, as: Int64.self)
                p.storeBytes(of: row.score, toByteOffset: 33, as: Float.self)
                p.storeBytes(of: row.pointStart, toByteOffset: 37, as: UInt64.self)
                p.storeBytes(of: row.pointEnd, toByteOffset: 45, as: UInt64.self)
                p.storeBytes(of: row.trackingScore, toByteOffset: 53, as: Float.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [rows.count])
        let ds = try file.createDataset(name: "instances", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
    }

    private static func writePointsDataset(
        _ points: [(x: Double, y: Double, visible: Bool, complete: Bool)],
        file: HDF5File, name: String
    ) throws {
        guard !points.isEmpty else { return }

        var offset = 0
        let compType = try HDF5Datatype.createCompound(size: 18)
        try compType.insertField(name: "x", offset: offset, type: shim_H5T_NATIVE_DOUBLE()); offset += 8
        try compType.insertField(name: "y", offset: offset, type: shim_H5T_NATIVE_DOUBLE()); offset += 8
        try compType.insertField(name: "visible", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        try compType.insertField(name: "complete", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        let rowSize = 18

        var buffer = Data(count: points.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, pt) in points.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: pt.x, toByteOffset: 0, as: Double.self)
                p.storeBytes(of: pt.y, toByteOffset: 8, as: Double.self)
                p.storeBytes(of: UInt8(pt.visible ? 1 : 0), toByteOffset: 16, as: UInt8.self)
                p.storeBytes(of: UInt8(pt.complete ? 1 : 0), toByteOffset: 17, as: UInt8.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [points.count])
        let ds = try file.createDataset(name: name, type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
    }

    private static func writePredPointsDataset(
        _ points: [(x: Double, y: Double, visible: Bool, complete: Bool, score: Double)],
        file: HDF5File
    ) throws {
        guard !points.isEmpty else { return }

        var offset = 0
        let compType = try HDF5Datatype.createCompound(size: 26)
        try compType.insertField(name: "x", offset: offset, type: shim_H5T_NATIVE_DOUBLE()); offset += 8
        try compType.insertField(name: "y", offset: offset, type: shim_H5T_NATIVE_DOUBLE()); offset += 8
        try compType.insertField(name: "visible", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        try compType.insertField(name: "complete", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        try compType.insertField(name: "score", offset: offset, type: shim_H5T_NATIVE_DOUBLE()); offset += 8
        let rowSize = 26

        var buffer = Data(count: points.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, pt) in points.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: pt.x, toByteOffset: 0, as: Double.self)
                p.storeBytes(of: pt.y, toByteOffset: 8, as: Double.self)
                p.storeBytes(of: UInt8(pt.visible ? 1 : 0), toByteOffset: 16, as: UInt8.self)
                p.storeBytes(of: UInt8(pt.complete ? 1 : 0), toByteOffset: 17, as: UInt8.self)
                p.storeBytes(of: pt.score, toByteOffset: 18, as: Double.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [points.count])
        let ds = try file.createDataset(name: "pred_points", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
    }

    // MARK: - Write negative frames

    private static func writeNegativeFrames(_ labels: Labels, file: HDF5File) throws {
        var negFrames: [(videoId: UInt32, frameIdx: UInt64)] = []

        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }

        for i in 0..<labels.frameStore.count {
            let frame = labels.frameStore.frame(at: i)
            if frame.isNegative {
                let vidIdx = videoIndexMap[ObjectIdentifier(frame.video)] ?? 0
                negFrames.append((videoId: UInt32(vidIdx), frameIdx: UInt64(frame.frameIndex)))
            }
        }

        guard !negFrames.isEmpty else { return }

        let compType = try HDF5Datatype.createCompound(size: 12)
        try compType.insertField(name: "video_id", offset: 0, type: shim_H5T_NATIVE_UINT32())
        try compType.insertField(name: "frame_idx", offset: 4, type: shim_H5T_NATIVE_UINT64())
        let rowSize = 12

        var buffer = Data(count: negFrames.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, nf) in negFrames.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: nf.videoId, toByteOffset: 0, as: UInt32.self)
                p.storeBytes(of: nf.frameIdx, toByteOffset: 4, as: UInt64.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [negFrames.count])
        let ds = try file.createDataset(name: "negative_frames", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }
    }

    // MARK: - Write suggestions

    private static func writeSuggestions(_ labels: Labels, file: HDF5File) throws {
        guard !labels.suggestions.isEmpty else { return }

        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }

        var strings: [String] = []
        for sug in labels.suggestions {
            var dict: [String: Any] = [:]
            dict["video"] = videoIndexMap[ObjectIdentifier(sug.video)] ?? 0
            dict["frame_idx"] = sug.frameIndex
            if let group = sug.group {
                dict["group"] = group
            }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            strings.append(String(data: data, encoding: .utf8) ?? "")
        }

        try file.writeVLenStringDataset(name: "suggestions_json", strings: strings)
    }

    // MARK: - Write sessions

    /// Write ``RecordingSession``s to `/sessions_json` using the Python-compatible
    /// schema (see ``SessionSchema``): `calibration` + `camcorder_to_video_idx_map`
    /// + `frame_group_dicts`, plus a legacy `camera_to_video` array for
    /// old-schema readers. Camera intrinsics/extrinsics/distortion are persisted
    /// via ``Camera``'s existing public API.
    private static func writeSessions(_ labels: Labels, file: HDF5File) throws {
        guard !labels.sessions.isEmpty else { return }

        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }

        // Index maps for frame-group serialization (mirrors Python's
        // labeled_frame_to_idx / instance_to_lf_and_inst_idx).
        var labeledFrameToIdx: [ObjectIdentifier: Int] = [:]
        var instanceToLfInst: [ObjectIdentifier: (Int, Int)] = [:]
        for i in 0..<labels.frameStore.count {
            let frame = labels.frameStore.frame(at: i)
            labeledFrameToIdx[ObjectIdentifier(frame)] = i
            for (instIdx, inst) in frame.instances.enumerated() {
                instanceToLfInst[ObjectIdentifier(inst)] = (i, instIdx)
            }
        }

        var strings: [String] = []
        for session in labels.sessions {
            let orderedCameras = SessionSchema.orderedCameras(for: session)
            let dict = SessionSchema.sessionDict(
                session,
                orderedCameras: orderedCameras,
                videoIndexMap: videoIndexMap,
                labeledFrameToIdx: labeledFrameToIdx,
                instanceToLfInst: instanceToLfInst
            )
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            strings.append(String(data: data, encoding: .utf8) ?? "{}")
        }

        try file.writeVLenStringDataset(name: "sessions_json", strings: strings)
    }

    // MARK: - Write ROIs

    private static func writeROIs(_ rois: [ROI], file: HDF5File) throws {
        guard !rois.isEmpty else { return }

        // Build WKB data
        var wkbData = Data()
        var wkbStarts: [UInt64] = []
        var wkbEnds: [UInt64] = []

        for roi in rois {
            wkbStarts.append(UInt64(wkbData.count))
            let wkb = encodeWKB(roi)
            wkbData.append(contentsOf: wkb)
            wkbEnds.append(UInt64(wkbData.count))
        }

        // Write /roi_wkb
        try file.writeDataset(name: "roi_wkb", data: [UInt8](wkbData), type: shim_H5T_NATIVE_UINT8())

        // Write /rois compound dataset
        let compType = try HDF5Datatype.createCompound(size: 40)
        var offset = 0
        try compType.insertField(name: "annotation_type", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        offset = 4
        try compType.insertField(name: "video", offset: offset, type: shim_H5T_NATIVE_INT32()); offset += 4
        try compType.insertField(name: "frame_idx", offset: offset, type: shim_H5T_NATIVE_INT64()); offset += 8
        try compType.insertField(name: "track", offset: offset, type: shim_H5T_NATIVE_INT32()); offset += 4
        try compType.insertField(name: "score", offset: offset, type: shim_H5T_NATIVE_FLOAT()); offset += 4
        try compType.insertField(name: "wkb_start", offset: offset, type: shim_H5T_NATIVE_UINT64()); offset += 8
        try compType.insertField(name: "wkb_end", offset: offset, type: shim_H5T_NATIVE_UINT64())
        let rowSize = 40

        var buffer = Data(count: rois.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, roi) in rois.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: encodeAnnotationType(roi.annotationType), toByteOffset: 0, as: UInt8.self)
                p.storeBytes(of: Int32(roi.videoIndex ?? -1), toByteOffset: 4, as: Int32.self)
                p.storeBytes(of: Int64(roi.frameIndex ?? -1), toByteOffset: 8, as: Int64.self)
                p.storeBytes(of: Int32(roi.trackIndex ?? -1), toByteOffset: 16, as: Int32.self)
                p.storeBytes(of: roi.score ?? 0.0, toByteOffset: 20, as: Float.self)
                p.storeBytes(of: wkbStarts[i], toByteOffset: 24, as: UInt64.self)
                p.storeBytes(of: wkbEnds[i], toByteOffset: 32, as: UInt64.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [rois.count])
        let ds = try file.createDataset(name: "rois", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }

        // Write metadata attributes
        let categories = rois.map { $0.category ?? "" }
        let names = rois.map { $0.name }
        let sources = rois.map { $0.source ?? "" }

        try writeJSONListAttribute(to: ds, name: "categories", values: categories)
        try writeJSONListAttribute(to: ds, name: "names", values: names)
        try writeJSONListAttribute(to: ds, name: "sources", values: sources)
    }

    // MARK: - Write masks

    private static func writeMasks(_ masks: [SegmentationMask], file: HDF5File) throws {
        guard !masks.isEmpty else { return }

        // Build RLE data
        var rleData = Data()
        var rleStarts: [UInt64] = []
        var rleEnds: [UInt64] = []

        for mask in masks {
            rleStarts.append(UInt64(rleData.count))
            for count in mask.rleCounts {
                var val = UInt32(count)
                withUnsafeBytes(of: &val) { rleData.append(contentsOf: $0) }
            }
            rleEnds.append(UInt64(rleData.count))
        }

        // Write /mask_rle
        try file.writeDataset(name: "mask_rle", data: [UInt8](rleData), type: shim_H5T_NATIVE_UINT8())

        // Write /masks compound dataset
        let compType = try HDF5Datatype.createCompound(size: 48)
        var offset = 0
        try compType.insertField(name: "height", offset: offset, type: shim_H5T_NATIVE_UINT32()); offset += 4
        try compType.insertField(name: "width", offset: offset, type: shim_H5T_NATIVE_UINT32()); offset += 4
        try compType.insertField(name: "annotation_type", offset: offset, type: shim_H5T_NATIVE_UINT8()); offset += 1
        offset = 12 // pad
        try compType.insertField(name: "video", offset: offset, type: shim_H5T_NATIVE_INT32()); offset += 4
        try compType.insertField(name: "frame_idx", offset: offset, type: shim_H5T_NATIVE_INT64()); offset += 8
        try compType.insertField(name: "track", offset: offset, type: shim_H5T_NATIVE_INT32()); offset += 4
        try compType.insertField(name: "score", offset: offset, type: shim_H5T_NATIVE_FLOAT()); offset += 4
        try compType.insertField(name: "rle_start", offset: offset, type: shim_H5T_NATIVE_UINT64()); offset += 8
        try compType.insertField(name: "rle_end", offset: offset, type: shim_H5T_NATIVE_UINT64())
        let rowSize = 48

        var buffer = Data(count: masks.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, mask) in masks.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: UInt32(mask.height), toByteOffset: 0, as: UInt32.self)
                p.storeBytes(of: UInt32(mask.width), toByteOffset: 4, as: UInt32.self)
                p.storeBytes(of: encodeAnnotationType(mask.annotationType), toByteOffset: 8, as: UInt8.self)
                p.storeBytes(of: Int32(mask.videoIndex ?? -1), toByteOffset: 12, as: Int32.self)
                p.storeBytes(of: Int64(mask.frameIndex ?? -1), toByteOffset: 16, as: Int64.self)
                p.storeBytes(of: Int32(mask.trackIndex ?? -1), toByteOffset: 24, as: Int32.self)
                p.storeBytes(of: mask.score ?? 0.0, toByteOffset: 28, as: Float.self)
                p.storeBytes(of: rleStarts[i], toByteOffset: 32, as: UInt64.self)
                p.storeBytes(of: rleEnds[i], toByteOffset: 40, as: UInt64.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [masks.count])
        let ds = try file.createDataset(name: "masks", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }

        let categories = masks.map { $0.category ?? "" }
        let names = masks.map { $0.name }
        let sources = masks.map { $0.source ?? "" }

        try writeJSONListAttribute(to: ds, name: "categories", values: categories)
        try writeJSONListAttribute(to: ds, name: "names", values: names)
        try writeJSONListAttribute(to: ds, name: "sources", values: sources)
    }

    // MARK: - Write identities

    /// Write ground-truth ``Identity`` annotations to `/identities_json` (one
    /// JSON blob per identity). Mirrors Python `write_identities`.
    private static func writeIdentities(_ identities: [Identity], file: HDF5File) throws {
        guard !identities.isEmpty else { return }

        var jsons: [String] = []
        jsons.reserveCapacity(identities.count)
        for identity in identities {
            var dict: [String: Any] = ["name": identity.name]
            if let color = identity.color {
                dict["color"] = color
            }
            for (key, value) in identity.metadata {
                dict[key] = value.jsonObject
            }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            jsons.append(String(data: data, encoding: .utf8) ?? "{}")
        }

        try file.writeVLenStringDataset(name: "identities_json", strings: jsons)
    }

    // MARK: - Write bounding boxes

    /// Write ``BoundingBox`` annotations to the `/bboxes` compound dataset.
    /// String metadata (categories/names/sources) is stored as JSON-list
    /// attributes, mirroring ``writeROIs`` / ``writeMasks``.
    private static func writeBboxes(_ bboxes: [BoundingBox], file: HDF5File) throws {
        guard !bboxes.isEmpty else { return }

        let rowSize = 72
        let compType = try HDF5Datatype.createCompound(size: rowSize)
        try compType.insertField(name: "x_center", offset: 0, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "y_center", offset: 8, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "width", offset: 16, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "height", offset: 24, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "angle", offset: 32, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "video", offset: 40, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "frame_idx", offset: 48, type: shim_H5T_NATIVE_INT64())
        try compType.insertField(name: "track", offset: 56, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "instance", offset: 60, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "is_predicted", offset: 64, type: shim_H5T_NATIVE_UINT8())
        try compType.insertField(name: "score", offset: 68, type: shim_H5T_NATIVE_FLOAT())

        var buffer = Data(count: bboxes.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, box) in bboxes.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: box.xCenter, toByteOffset: 0, as: Double.self)
                p.storeBytes(of: box.yCenter, toByteOffset: 8, as: Double.self)
                p.storeBytes(of: box.width, toByteOffset: 16, as: Double.self)
                p.storeBytes(of: box.height, toByteOffset: 24, as: Double.self)
                p.storeBytes(of: box.angle, toByteOffset: 32, as: Double.self)
                p.storeBytes(of: Int32(box.videoIndex ?? -1), toByteOffset: 40, as: Int32.self)
                p.storeBytes(of: Int64(box.frameIndex ?? -1), toByteOffset: 48, as: Int64.self)
                p.storeBytes(of: Int32(box.trackIndex ?? -1), toByteOffset: 56, as: Int32.self)
                p.storeBytes(of: Int32(box.instanceIndex ?? -1), toByteOffset: 60, as: Int32.self)
                p.storeBytes(of: UInt8(box.isPredicted ? 1 : 0), toByteOffset: 64, as: UInt8.self)
                p.storeBytes(of: box.score ?? Float.nan, toByteOffset: 68, as: Float.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [bboxes.count])
        let ds = try file.createDataset(name: "bboxes", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }

        try writeJSONListAttribute(to: ds, name: "categories", values: bboxes.map { $0.category ?? "" })
        try writeJSONListAttribute(to: ds, name: "names", values: bboxes.map { $0.name ?? "" })
        try writeJSONListAttribute(to: ds, name: "sources", values: bboxes.map { $0.source ?? "" })
    }

    // MARK: - Write centroids

    /// Write ``Centroid`` annotations to the `/centroids` compound dataset,
    /// following the `/bboxes` layout.
    private static func writeCentroids(_ centroids: [Centroid], file: HDF5File) throws {
        guard !centroids.isEmpty else { return }

        let rowSize = 48
        let compType = try HDF5Datatype.createCompound(size: rowSize)
        try compType.insertField(name: "x", offset: 0, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "y", offset: 8, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "video", offset: 16, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "frame_idx", offset: 24, type: shim_H5T_NATIVE_INT64())
        try compType.insertField(name: "track", offset: 32, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "instance", offset: 36, type: shim_H5T_NATIVE_INT32())
        try compType.insertField(name: "is_predicted", offset: 40, type: shim_H5T_NATIVE_UINT8())
        try compType.insertField(name: "score", offset: 44, type: shim_H5T_NATIVE_FLOAT())

        var buffer = Data(count: centroids.count * rowSize)
        buffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, c) in centroids.enumerated() {
                let p = base + i * rowSize
                p.storeBytes(of: c.x, toByteOffset: 0, as: Double.self)
                p.storeBytes(of: c.y, toByteOffset: 8, as: Double.self)
                p.storeBytes(of: Int32(c.videoIndex ?? -1), toByteOffset: 16, as: Int32.self)
                p.storeBytes(of: Int64(c.frameIndex ?? -1), toByteOffset: 24, as: Int64.self)
                p.storeBytes(of: Int32(c.trackIndex ?? -1), toByteOffset: 32, as: Int32.self)
                p.storeBytes(of: Int32(c.instanceIndex ?? -1), toByteOffset: 36, as: Int32.self)
                p.storeBytes(of: UInt8(c.isPredicted ? 1 : 0), toByteOffset: 40, as: UInt8.self)
                p.storeBytes(of: c.score ?? Float.nan, toByteOffset: 44, as: Float.self)
            }
        }

        let space = try HDF5Dataspace.create(dims: [centroids.count])
        let ds = try file.createDataset(name: "centroids", type: compType, space: space)
        try buffer.withUnsafeBytes { ptr in
            try ds.writeRaw(ptr.baseAddress!, memType: compType.id)
        }

        try writeJSONListAttribute(to: ds, name: "categories", values: centroids.map { $0.category ?? "" })
        try writeJSONListAttribute(to: ds, name: "names", values: centroids.map { $0.name ?? "" })
        try writeJSONListAttribute(to: ds, name: "sources", values: centroids.map { $0.source ?? "" })
    }

    // MARK: - Write label images

    /// Write ``LabelImage`` annotations across the `/label_images`,
    /// `/label_image_objects`, and `/label_image_data` datasets.
    ///
    /// The layout mirrors Python sleap-io's `write_label_images` dataset names and
    /// per-image compound fields (`video`, `frame_idx`, `height`, `width`,
    /// `n_objects`, `objects_start`, `data_start`, `data_end`) with two Swift-port
    /// adaptations: pixel data is stored as a flat rank-1 **int32** dataset
    /// (`data_start`/`data_end` are element offsets, read back one image at a time
    /// via a hyperslab) rather than a zlib-compressed uint8 stream, and there is no
    /// predicted variant. Object metadata (`categories`/`names`) rides on
    /// JSON-list attributes exactly as ``writeROIs`` / ``writeBboxes`` do.
    private static func writeLabelImages(_ labelImages: [LabelImage], file: HDF5File) throws {
        guard !labelImages.isEmpty else { return }

        // Flat pixel buffer + per-image element offsets, plus the object table.
        var pixelData: [Int32] = []
        var liRows: [(video: Int32, frameIdx: Int64, height: UInt32, width: UInt32,
                      nObjects: UInt32, objectsStart: UInt32,
                      dataStart: UInt64, dataEnd: UInt64)] = []
        var objRows: [(labelID: Int32, track: Int32, instance: Int32)] = []
        var categories: [String] = []
        var names: [String] = []
        var sources: [String] = []
        var objOffset = 0

        for li in labelImages {
            let dataStart = pixelData.count
            pixelData.append(contentsOf: li.data)
            let dataEnd = pixelData.count

            let objectsStart = objOffset
            for labelID in li.objects.keys.sorted() {
                let info = li.objects[labelID]!
                objRows.append((
                    labelID: Int32(labelID),
                    track: Int32(info.trackIndex ?? -1),
                    instance: Int32(info.instanceIndex ?? -1)))
                categories.append(info.category)
                names.append(info.name)
            }
            objOffset += li.objects.count

            liRows.append((
                video: Int32(li.videoIndex ?? -1),
                frameIdx: Int64(li.frameIndex ?? -1),
                height: UInt32(li.height),
                width: UInt32(li.width),
                nObjects: UInt32(li.objects.count),
                objectsStart: UInt32(objectsStart),
                dataStart: UInt64(dataStart),
                dataEnd: UInt64(dataEnd)))
            sources.append(li.source)
        }

        // /label_images compound table.
        let liRowSize = 44
        let liType = try HDF5Datatype.createCompound(size: liRowSize)
        try liType.insertField(name: "video", offset: 0, type: shim_H5T_NATIVE_INT32())
        try liType.insertField(name: "frame_idx", offset: 4, type: shim_H5T_NATIVE_INT64())
        try liType.insertField(name: "height", offset: 12, type: shim_H5T_NATIVE_UINT32())
        try liType.insertField(name: "width", offset: 16, type: shim_H5T_NATIVE_UINT32())
        try liType.insertField(name: "n_objects", offset: 20, type: shim_H5T_NATIVE_UINT32())
        try liType.insertField(name: "objects_start", offset: 24, type: shim_H5T_NATIVE_UINT32())
        try liType.insertField(name: "data_start", offset: 28, type: shim_H5T_NATIVE_UINT64())
        try liType.insertField(name: "data_end", offset: 36, type: shim_H5T_NATIVE_UINT64())

        var liBuffer = Data(count: liRows.count * liRowSize)
        liBuffer.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!
            for (i, row) in liRows.enumerated() {
                let p = base + i * liRowSize
                p.storeBytes(of: row.video, toByteOffset: 0, as: Int32.self)
                p.storeBytes(of: row.frameIdx, toByteOffset: 4, as: Int64.self)
                p.storeBytes(of: row.height, toByteOffset: 12, as: UInt32.self)
                p.storeBytes(of: row.width, toByteOffset: 16, as: UInt32.self)
                p.storeBytes(of: row.nObjects, toByteOffset: 20, as: UInt32.self)
                p.storeBytes(of: row.objectsStart, toByteOffset: 24, as: UInt32.self)
                p.storeBytes(of: row.dataStart, toByteOffset: 28, as: UInt64.self)
                p.storeBytes(of: row.dataEnd, toByteOffset: 36, as: UInt64.self)
            }
        }

        let liSpace = try HDF5Dataspace.create(dims: [liRows.count])
        let liDs = try file.createDataset(name: "label_images", type: liType, space: liSpace)
        try liBuffer.withUnsafeBytes { ptr in
            try liDs.writeRaw(ptr.baseAddress!, memType: liType.id)
        }
        try writeJSONListAttribute(to: liDs, name: "sources", values: sources)

        // /label_image_objects compound table (skip when there are no objects —
        // a zero-row compound write is unrepresentable; the reader tolerates it).
        if !objRows.isEmpty {
            let objRowSize = 12
            let objType = try HDF5Datatype.createCompound(size: objRowSize)
            try objType.insertField(name: "label_id", offset: 0, type: shim_H5T_NATIVE_INT32())
            try objType.insertField(name: "track", offset: 4, type: shim_H5T_NATIVE_INT32())
            try objType.insertField(name: "instance", offset: 8, type: shim_H5T_NATIVE_INT32())

            var objBuffer = Data(count: objRows.count * objRowSize)
            objBuffer.withUnsafeMutableBytes { ptr in
                let base = ptr.baseAddress!
                for (i, row) in objRows.enumerated() {
                    let p = base + i * objRowSize
                    p.storeBytes(of: row.labelID, toByteOffset: 0, as: Int32.self)
                    p.storeBytes(of: row.track, toByteOffset: 4, as: Int32.self)
                    p.storeBytes(of: row.instance, toByteOffset: 8, as: Int32.self)
                }
            }

            let objSpace = try HDF5Dataspace.create(dims: [objRows.count])
            let objDs = try file.createDataset(name: "label_image_objects", type: objType, space: objSpace)
            try objBuffer.withUnsafeBytes { ptr in
                try objDs.writeRaw(ptr.baseAddress!, memType: objType.id)
            }
            try writeJSONListAttribute(to: objDs, name: "categories", values: categories)
            try writeJSONListAttribute(to: objDs, name: "names", values: names)
        }

        // /label_image_data flat int32 pixel buffer. The reader gates on this
        // dataset's presence, so only write it when there are pixels.
        if !pixelData.isEmpty {
            try file.writeDataset(name: "label_image_data", data: pixelData,
                                  type: shim_H5T_NATIVE_INT32())
        }
    }

    // MARK: - Helpers

    private static func encodeAnnotationType(_ type: AnnotationType) -> UInt8 {
        switch type {
        case .boundingBox: return 0
        case .polygon: return 1
        case .polyline: return 2
        case .point: return 3
        case .ellipse: return 4
        case .segmentationMask: return 5
        }
    }

    private static func encodeWKB(_ roi: ROI) -> [UInt8] {
        var data = Data()

        // Byte order: little-endian
        data.append(1)

        switch roi.annotationType {
        case .point:
            // WKB Point
            var geomType: UInt32 = 1
            withUnsafeBytes(of: &geomType) { data.append(contentsOf: $0) }
            if let p = roi.points.first {
                var x = Double(p.x); var y = Double(p.y)
                withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            }
        case .polyline:
            // WKB LineString
            var geomType: UInt32 = 2
            withUnsafeBytes(of: &geomType) { data.append(contentsOf: $0) }
            var numPoints = UInt32(roi.points.count)
            withUnsafeBytes(of: &numPoints) { data.append(contentsOf: $0) }
            for p in roi.points {
                var x = Double(p.x); var y = Double(p.y)
                withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            }
        default:
            // WKB Polygon (default for bounding box, polygon, ellipse)
            var geomType: UInt32 = 3
            withUnsafeBytes(of: &geomType) { data.append(contentsOf: $0) }
            var numRings: UInt32 = 1
            withUnsafeBytes(of: &numRings) { data.append(contentsOf: $0) }
            // Close the ring
            var pts = roi.points
            if let first = pts.first, pts.last != first {
                pts.append(first)
            }
            var numPoints = UInt32(pts.count)
            withUnsafeBytes(of: &numPoints) { data.append(contentsOf: $0) }
            for p in pts {
                var x = Double(p.x); var y = Double(p.y)
                withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            }
        }

        return [UInt8](data)
    }

    private static func writeJSONListAttribute(to ds: HDF5Dataset, name: String, values: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: values)
        let jsonStr = String(data: data, encoding: .utf8) ?? "[]"
        try ds.writeStringAttribute(name: name, value: jsonStr)
    }
}

import Foundation
import CHDF5
import SleapIO

/// Writes SLEAP .slp files (HDF5-based).
public struct SLPWriter {

    /// Write a Labels object to an SLP file.
    public static func write(_ labels: Labels, to path: String) async throws {
        let actor = try HDF5FileActor.create(path: path)
        try await actor.withFile { file in
            try writeToFile(labels, file: file)
        }
    }

    /// Write to an open HDF5File (internal).
    static func writeToFile(_ labels: Labels, file: HDF5File) throws {
        let hasROIs = !labels.rois.isEmpty
        let hasMasks = !labels.masks.isEmpty
        let formatId: Float = (hasROIs || hasMasks) ? 1.5 : 1.4

        // 1. Write metadata
        try writeMetadata(labels, file: file, formatId: formatId)

        // 2. Write tracks
        try writeTracks(labels.tracks, file: file)

        // 3. Write videos
        try writeVideos(labels.videos, file: file)

        // 4. Collect and write compound datasets
        try writeCompoundData(labels, file: file)

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
    }

    // MARK: - Write metadata

    private static func writeMetadata(_ labels: Labels, file: HDF5File, formatId: Float) throws {
        let metaGroup = try file.createGroup(name: "metadata")
        try metaGroup.writeFloatAttribute(name: "format_id", value: formatId)

        // Build metadata JSON with skeletons and provenance
        var metaDict: [String: Any] = [:]
        metaDict["version"] = "2.0.0"
        metaDict["provenance"] = labels.provenance

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

    private static func writeVideos(_ videos: [Video], file: HDF5File) throws {
        guard !videos.isEmpty else { return }
        var videoJsons: [String] = []
        for video in videos {
            var dict: [String: Any] = [:]
            var backend: [String: Any] = video.backendMetadata
            backend["filename"] = video.filename
            backend["type"] = video.backendType
            dict["backend"] = backend
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            videoJsons.append(String(data: data, encoding: .utf8) ?? "")
        }
        try file.writeVLenStringDataset(name: "videos_json", strings: videoJsons)
    }

    // MARK: - Write compound datasets (frames, instances, points, pred_points)

    private static func writeCompoundData(_ labels: Labels, file: HDF5File) throws {
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
            let frame = labels.frameStore.frame(at: i)
            for inst in frame.instances {
                instanceIndexMap[ObjectIdentifier(inst)] = globalInstanceIdx
                globalInstanceIdx += 1
            }
        }

        var instanceIdx = 0
        for i in 0..<labels.frameStore.count {
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

        // Create compound type matching Python's layout
        let compSize = 5 * 8 // approximate
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
        let compType = try HDF5Datatype.createCompound(size: 72) // generous
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

    private static func writeSessions(_ labels: Labels, file: HDF5File) throws {
        guard !labels.sessions.isEmpty else { return }

        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }

        var strings: [String] = []
        for session in labels.sessions {
            var camVideos: [[String: Any]] = []
            for (camera, video) in session.cameraToVideo {
                let videoIdx = videoIndexMap[ObjectIdentifier(video)] ?? 0
                camVideos.append([
                    "camera_name": camera.name,
                    "video_idx": videoIdx
                ])
            }
            let dict: [String: Any] = ["camera_to_video": camVideos]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            strings.append(String(data: data, encoding: .utf8) ?? "")
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
        let compType = try HDF5Datatype.createCompound(size: 32)
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
        let compType = try HDF5Datatype.createCompound(size: 40)
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

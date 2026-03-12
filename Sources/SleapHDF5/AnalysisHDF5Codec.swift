import Foundation
import CHDF5
import SleapIO

/// Codec for reading and writing SLEAP analysis HDF5 files.
///
/// Analysis HDF5 is a dense array format where pose data is stored as
/// multi-dimensional arrays indexed by (frame, track, node, xy).
/// One file corresponds to one video.
public struct AnalysisHDF5Codec {

    // MARK: - Read

    /// Read an analysis HDF5 file into a Labels object.
    ///
    /// The import is always eager (non-lazy). One file maps to one Video.
    /// If score datasets are present, instances are `PredictedInstance`;
    /// otherwise they are plain `Instance`.
    ///
    /// - Parameter path: Path to the `.h5` analysis file.
    /// - Returns: A fully materialized `Labels` object.
    /// - Throws: `SleapIOError.fileNotFound` if path doesn't exist,
    ///           `SleapIOError.corruptData` if the file can't be opened or
    ///           required datasets are missing or have wrong shape.
    public static func read(from path: String) throws -> Labels {
        let file: HDF5File
        do {
            file = try HDF5File.openReadOnly(path: path)
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                throw SleapIOError.fileNotFound("File not found: \(path)")
            }
            throw SleapIOError.corruptData("Cannot open HDF5 file: \(path)")
        }

        // Read track names (dataset may be named "track_names" or "tracks")
        let trackNames: [String]
        if file.exists(name: "track_names") {
            let ds = try openRequiredDataset(file, name: "track_names")
            trackNames = try ds.readVLenStrings()
        } else if file.exists(name: "tracks") {
            let ds = try openRequiredDataset(file, name: "tracks")
            trackNames = try ds.readVLenStrings()
        } else {
            throw SleapIOError.corruptData("Missing required dataset: track_names or tracks")
        }

        // Read node names
        let nodeNames: [String]
        do {
            let ds = try openRequiredDataset(file, name: "node_names")
            nodeNames = try ds.readVLenStrings()
        }

        // Read locations: (T, N, K, 2)
        let locationsDS = try openRequiredDataset(file, name: "locations")
        let locShape = locationsDS.shape
        guard locShape.count == 4 && locShape[3] == 2 else {
            throw SleapIOError.corruptData(
                "locations dataset has unexpected shape \(locShape), expected (T, N, K, 2)")
        }
        let T = locShape[0]  // frames
        let N = locShape[1]  // tracks
        let K = locShape[2]  // nodes
        let locations = try locationsDS.readFloat64()

        guard nodeNames.count == K else {
            throw SleapIOError.corruptData(
                "node_names count (\(nodeNames.count)) != locations node dim (\(K))")
        }
        guard trackNames.count == N else {
            throw SleapIOError.corruptData(
                "track_names count (\(trackNames.count)) != locations track dim (\(N))")
        }

        // Read track occupancy: (T, N) as uint8
        let occupancy: [UInt8]
        do {
            let ds = try openRequiredDataset(file, name: "track_occupancy")
            let occShape = ds.shape
            guard occShape == [T, N] else {
                throw SleapIOError.corruptData(
                    "track_occupancy shape \(occShape) doesn't match (T=\(T), N=\(N))")
            }
            occupancy = try ds.readUInt8()
        }

        // Read optional score datasets
        let hasPointScores = file.exists(name: "point_scores")
        let hasInstanceScores = file.exists(name: "instance_scores")
        let hasTrackingScores = file.exists(name: "tracking_scores")
        let hasPredictions = hasPointScores || hasInstanceScores || hasTrackingScores

        var pointScores: [Double]?
        var instanceScores: [Double]?
        var trackingScores: [Double]?

        if hasPointScores {
            let ds = try file.openDataset(name: "point_scores")
            pointScores = try ds.readFloat64()
        }
        if hasInstanceScores {
            let ds = try file.openDataset(name: "instance_scores")
            instanceScores = try ds.readFloat64()
        }
        if hasTrackingScores {
            let ds = try file.openDataset(name: "tracking_scores")
            trackingScores = try ds.readFloat64()
        }

        // Read optional edge data
        var edgeIndices: [Int32]?
        if file.exists(name: "edge_inds") {
            let ds = try file.openDataset(name: "edge_inds")
            edgeIndices = try ds.readInt32()
        }

        // Read video_path attribute (optional)
        let videoPath: String
        do {
            videoPath = try file.readStringAttribute(name: "video_path")
        } catch {
            videoPath = path
        }

        // Build model objects

        // Nodes
        let nodes = nodeNames.map { Node(name: $0) }

        // Skeleton
        let skeleton = Skeleton(name: "Skeleton", nodes: nodes)

        // Edges
        if let edgeInds = edgeIndices, edgeInds.count >= 2 {
            let edgeCount = edgeInds.count / 2
            for e in 0..<edgeCount {
                let i0 = e * 2, i1 = e * 2 + 1
                guard i1 < edgeInds.count else { break }
                let srcIdx = Int(edgeInds[i0])
                let dstIdx = Int(edgeInds[i1])
                if srcIdx >= 0 && srcIdx < K && dstIdx >= 0 && dstIdx < K {
                    skeleton.addEdge(from: nodes[srcIdx], to: nodes[dstIdx])
                }
            }
        }

        // Tracks
        let tracks = trackNames.map { Track(name: $0) }

        // Video
        let video = Video(filename: videoPath)

        // Build frames
        var frames: [LabeledFrame] = []
        frames.reserveCapacity(T)

        for t in 0..<T {
            var instances: [Instance] = []

            for n in 0..<N {
                // Check occupancy
                let occIdx = t * N + n
                guard occupancy[occIdx] != 0 else { continue }

                // Single pass: build coords and check for all-NaN simultaneously
                let baseIdx = ((t * N + n) * K) * 2
                var coords = ContiguousArray<Float>(repeating: 0, count: K * 2)
                var vis = ContiguousArray<Bool>(repeating: false, count: K)
                var comp = ContiguousArray<Bool>(repeating: false, count: K)
                var hasAnyData = false

                for k in 0..<K {
                    let x = locations[baseIdx + k * 2]
                    let y = locations[baseIdx + k * 2 + 1]
                    coords[k * 2] = Float(x)
                    coords[k * 2 + 1] = Float(y)
                    let isVisible = !x.isNaN && !y.isNaN
                    vis[k] = isVisible
                    comp[k] = isVisible
                    if isVisible { hasAnyData = true }
                }

                guard hasAnyData else { continue }

                let pointsArray = PointsArray(
                    coordinates: coords,
                    visibility: vis,
                    completeness: comp
                )

                if hasPredictions {
                    var scores = ContiguousArray<Float>(repeating: 0, count: K)
                    if let ps = pointScores {
                        let psBase = (t * N + n) * K
                        for k in 0..<K { scores[k] = Float(ps[psBase + k]) }
                    }
                    let predPoints = PredictedPointsArray(
                        pointsArray: pointsArray,
                        scores: scores
                    )
                    let instScore = instanceScores.map { Float($0[t * N + n]) } ?? 0.0
                    let trackScore = trackingScores.map { Float($0[t * N + n]) }

                    instances.append(PredictedInstance(
                        skeleton: skeleton,
                        points: predPoints,
                        score: instScore,
                        track: tracks[n],
                        trackingScore: trackScore
                    ))
                } else {
                    instances.append(Instance(
                        skeleton: skeleton,
                        points: pointsArray,
                        track: tracks[n]
                    ))
                }
            }

            // Only create frame if it has instances
            if !instances.isEmpty {
                let frame = LabeledFrame(
                    video: video,
                    frameIndex: t,
                    instances: instances
                )
                frames.append(frame)
            }
        }

        let store = EagerFrameStore(frames: frames)
        return Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: tracks
        )
    }

    // MARK: - Write

    /// Write a Labels object to an analysis HDF5 file.
    ///
    /// - Parameters:
    ///   - labels: The labels to write. Must have exactly one skeleton.
    ///   - path: Output file path.
    /// - Throws: `SleapIOError.unsupportedFormat` if labels has more than one skeleton.
    public static func write(_ labels: Labels, to path: String) throws {
        guard labels.skeletons.count <= 1 else {
            throw SleapIOError.unsupportedFormat(
                "Analysis HDF5 format supports only one skeleton, found \(labels.skeletons.count)")
        }
        guard labels.videos.count <= 1 else {
            throw SleapIOError.unsupportedFormat(
                "Analysis HDF5 format supports only one video, found \(labels.videos.count)")
        }

        let file: HDF5File
        do {
            file = try HDF5File.create(path: path)
        } catch {
            throw SleapIOError.corruptData("Cannot create HDF5 file: \(path)")
        }

        guard let skeleton = labels.skeleton else {
            // Empty labels — write minimal file
            try writeEmptyFile(file: file, labels: labels)
            return
        }

        let nodes = skeleton.nodes
        let K = nodes.count

        // For trackless data (e.g. single-animal DLC import), assign instances
        // to a synthetic track so the (T,N,K,2) tensor has N >= 1.
        let tracks: [Track]
        let trackIndex: [ObjectIdentifier: Int]
        let isTrackless = labels.tracks.isEmpty

        if isTrackless {
            // Count max instances per frame to determine N
            var maxInst = 0
            for i in 0..<labels.frameCount {
                maxInst = max(maxInst, labels[i].instances.count)
            }
            let N = max(maxInst, 1)
            var syntheticTracks: [Track] = []
            var syntheticIndex: [ObjectIdentifier: Int] = [:]
            for n in 0..<N {
                let t = Track(name: "track_\(n)")
                syntheticTracks.append(t)
                syntheticIndex[ObjectIdentifier(t)] = n
            }
            tracks = syntheticTracks
            trackIndex = syntheticIndex
        } else {
            tracks = labels.tracks
            var idx: [ObjectIdentifier: Int] = [:]
            for (i, track) in tracks.enumerated() {
                idx[ObjectIdentifier(track)] = i
            }
            trackIndex = idx
        }

        let N = tracks.count

        // Determine frame range: 0 to max frameIndex
        let maxFrameIndex = (0..<labels.frameCount).map { labels[$0].frameIndex }.max() ?? 0
        let T = labels.frameCount > 0 ? (maxFrameIndex + 1) : 0

        // Allocate arrays
        var locations = [Double](repeating: Double.nan, count: T * N * K * 2)
        var occupancy = [UInt8](repeating: 0, count: T * N)

        // Determine if we have any predicted instances
        var hasPredictions = false
        for i in 0..<labels.frameCount {
            if labels[i].instances.contains(where: { $0 is PredictedInstance }) {
                hasPredictions = true
                break
            }
        }

        var pointScores: [Double]?
        var instanceScores: [Double]?
        var trackingScores: [Double]?
        if hasPredictions {
            pointScores = [Double](repeating: 0, count: T * N * K)
            instanceScores = [Double](repeating: 0, count: T * N)
            trackingScores = [Double](repeating: 0, count: T * N)
        }

        // Fill arrays from labels
        for i in 0..<labels.frameCount {
            let frame = labels[i]
            let t = frame.frameIndex

            for (instIdx, inst) in frame.instances.enumerated() {
                let n: Int
                if isTrackless {
                    // Assign by position within the frame
                    n = instIdx
                    guard n < N else { continue }
                } else {
                    guard let track = inst.track,
                          let idx = trackIndex[ObjectIdentifier(track)] else {
                        continue
                    }
                    n = idx
                }

                let occIdx = t * N + n
                occupancy[occIdx] = 1

                // Write coordinates
                let baseIdx = ((t * N + n) * K) * 2
                for k in 0..<min(K, inst.points.count) {
                    let pt = inst.points[k]
                    locations[baseIdx + k * 2] = Double(pt.x)
                    locations[baseIdx + k * 2 + 1] = Double(pt.y)
                }

                // Write scores if predicted
                if let pred = inst as? PredictedInstance {
                    if instanceScores != nil {
                        instanceScores![occIdx] = Double(pred.score)
                    }
                    if trackingScores != nil {
                        trackingScores![occIdx] = Double(pred.trackingScore ?? 0.0)
                    }
                    if pointScores != nil {
                        let psBase = (t * N + n) * K
                        for k in 0..<min(K, pred.predictedPoints.count) {
                            pointScores![psBase + k] = Double(pred.predictedPoints[k].score)
                        }
                    }
                }
            }
        }

        // Write datasets

        // track_names
        let trackNameStrings = tracks.map { $0.name }
        try file.writeVLenStringDataset(name: "track_names", strings: trackNameStrings)

        // node_names
        let nodeNameStrings = nodes.map { $0.name }
        try file.writeVLenStringDataset(name: "node_names", strings: nodeNameStrings)

        // track_occupancy: (T, N) uint8
        try writeNDDataset(file: file, name: "track_occupancy", data: occupancy,
                           dims: [T, N], nativeType: shim_H5T_NATIVE_UINT8())

        // locations: (T, N, K, 2) float64
        try writeNDDataset(file: file, name: "locations", data: locations,
                           dims: [T, N, K, 2], nativeType: shim_H5T_NATIVE_DOUBLE())

        // Score datasets
        if let ps = pointScores {
            try writeNDDataset(file: file, name: "point_scores", data: ps,
                               dims: [T, N, K], nativeType: shim_H5T_NATIVE_DOUBLE())
        }
        if let is_ = instanceScores {
            try writeNDDataset(file: file, name: "instance_scores", data: is_,
                               dims: [T, N], nativeType: shim_H5T_NATIVE_DOUBLE())
        }
        if let ts = trackingScores {
            try writeNDDataset(file: file, name: "tracking_scores", data: ts,
                               dims: [T, N], nativeType: shim_H5T_NATIVE_DOUBLE())
        }

        // edge_inds and edge_names
        if !skeleton.edges.isEmpty {
            var edgeInds = [Int32]()
            var edgeNames = [String]()
            edgeInds.reserveCapacity(skeleton.edges.count * 2)
            edgeNames.reserveCapacity(skeleton.edges.count)

            for edge in skeleton.edges {
                if let srcIdx = skeleton.index(of: edge.source),
                   let dstIdx = skeleton.index(of: edge.destination) {
                    edgeInds.append(Int32(srcIdx))
                    edgeInds.append(Int32(dstIdx))
                    edgeNames.append("\(edge.source.name),\(edge.destination.name)")
                }
            }

            let E = skeleton.edges.count
            try writeNDDataset(file: file, name: "edge_inds", data: edgeInds,
                               dims: [E, 2], nativeType: shim_H5T_NATIVE_INT32())
            try file.writeVLenStringDataset(name: "edge_names", strings: edgeNames)
        }

        // video_path attribute
        if let video = labels.video {
            try file.writeStringAttribute(name: "video_path", value: video.filename)
        }
    }

    // MARK: - Private helpers

    /// Open a required dataset, throwing corruptData if not found.
    private static func openRequiredDataset(_ file: HDF5File, name: String) throws -> HDF5Dataset {
        guard file.exists(name: name) else {
            throw SleapIOError.corruptData("Missing required dataset: \(name)")
        }
        do {
            return try file.openDataset(name: name)
        } catch {
            throw SleapIOError.corruptData("Cannot open dataset: \(name)")
        }
    }

    /// Write an N-dimensional dataset with the given shape.
    private static func writeNDDataset<T>(
        file: HDF5File,
        name: String,
        data: [T],
        dims: [Int],
        nativeType: hid_t
    ) throws {
        let space = try HDF5Dataspace.create(dims: dims)
        let dtype = try HDF5Datatype.copy(nativeType)
        let ds = try file.createDataset(name: name, type: dtype, space: space)
        try ds.write(data, memType: nativeType)
    }

    /// Write a minimal file for empty labels.
    private static func writeEmptyFile(file: HDF5File, labels: Labels) throws {
        try file.writeVLenStringDataset(name: "track_names", strings: [])
        try file.writeVLenStringDataset(name: "node_names", strings: [])
        try writeNDDataset(file: file, name: "track_occupancy", data: [UInt8](),
                           dims: [0, 0], nativeType: shim_H5T_NATIVE_UINT8())
        try writeNDDataset(file: file, name: "locations", data: [Double](),
                           dims: [0, 0, 0, 2], nativeType: shim_H5T_NATIVE_DOUBLE())
        if let video = labels.video {
            try file.writeStringAttribute(name: "video_path", value: video.filename)
        }
    }
}

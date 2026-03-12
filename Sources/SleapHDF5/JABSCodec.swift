import Foundation
import CHDF5
import SleapIO

/// Codec for reading and writing JABS (JAX Animal Behavior System) HDF5 pose files.
///
/// JABS stores pose data in HDF5 files with a `poseest` group containing:
/// - `poseest/points`: (T, N, K, 2) float32 coordinates (NaN where absent)
/// - `poseest/confidence`: (T, N, K) float32 per-point confidence
///
/// Optional root attributes:
/// - `node_names`: string array of bodypart names
/// - `num_animals`: integer
public struct JABSCodec {

    /// Configuration for JABS import/export.
    public struct Config {
        /// Explicit node names. Used when the file lacks a `node_names` attribute.
        public let nodeNames: [String]?

        public init(nodeNames: [String]? = nil) {
            self.nodeNames = nodeNames
        }
    }

    // MARK: - Read

    /// Read a JABS HDF5 file into a Labels object.
    ///
    /// - Parameters:
    ///   - path: Path to the `.h5` file.
    ///   - config: Configuration with optional node names.
    /// - Returns: A fully materialized `Labels` instance.
    /// - Throws: `SleapIOError.fileNotFound`, `.corruptData`, `.invalidSkeleton`
    public static func read(from path: String, config: Config = Config()) throws -> Labels {
        let file: HDF5File
        do {
            file = try HDF5File.openReadOnly(path: path)
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                throw SleapIOError.fileNotFound(path)
            }
            throw SleapIOError.corruptData("Cannot open HDF5 file: \(path)")
        }

        // Open poseest group
        let poseest: HDF5Group
        do {
            poseest = try file.openGroup(name: "poseest")
        } catch {
            throw SleapIOError.corruptData("Missing 'poseest' group in JABS file: \(path)")
        }

        // Read points dataset
        let pointsDS: HDF5Dataset
        do {
            pointsDS = try poseest.openDataset(name: "points")
        } catch {
            throw SleapIOError.corruptData("Missing 'poseest/points' dataset in JABS file: \(path)")
        }

        let pointsShape = pointsDS.shape
        guard pointsShape.count == 4 else {
            throw SleapIOError.corruptData(
                "poseest/points must be 4D (T, N, K, 2), got \(pointsShape.count)D")
        }

        let T = pointsShape[0]  // frames
        let N = pointsShape[1]  // animals
        let K = pointsShape[2]  // keypoints
        let coordDim = pointsShape[3]

        guard coordDim == 2 else {
            throw SleapIOError.corruptData(
                "poseest/points last dimension must be 2 (x, y), got \(coordDim)")
        }

        // Determine node names: file attr > config > throw
        let nodeNames: [String]
        if HDF5Attribute.exists(on: file.id, name: "node_names") {
            nodeNames = try readStringArrayAttribute(from: file.id, name: "node_names")
        } else if let configNames = config.nodeNames {
            nodeNames = configNames
        } else {
            throw SleapIOError.invalidSkeleton(
                "No node_names attribute in file and none provided in config")
        }

        guard nodeNames.count == K else {
            throw SleapIOError.invalidSkeleton(
                "Node names count (\(nodeNames.count)) does not match keypoint count (\(K))")
        }

        // Read flat float32 arrays
        let pointsFlat = try pointsDS.readFloat32()  // T * N * K * 2

        // Read confidence if present
        let confidenceFlat: [Float]?
        if poseest.exists(name: "confidence") {
            let confDS = try poseest.openDataset(name: "confidence")
            confidenceFlat = try confDS.readFloat32()  // T * N * K
        } else {
            confidenceFlat = nil
        }

        let hasConfidence = confidenceFlat != nil

        // Build shared identity objects
        let skeleton = Skeleton(
            name: "JABS",
            nodes: nodeNames.map { Node(name: $0) }
        )

        let video = Video(filename: path)

        var tracks: [Track] = []
        for n in 0..<N {
            tracks.append(Track(name: "animal_\(n)"))
        }

        // Build frames
        var frames: [LabeledFrame] = []
        frames.reserveCapacity(T)

        for t in 0..<T {
            var instances: [Instance] = []

            for n in 0..<N {
                // Check if this animal is present (not fully NaN)
                let baseIdx = (t * N * K * 2) + (n * K * 2)
                var allNaN = true
                for k in 0..<K {
                    let x = pointsFlat[baseIdx + k * 2]
                    let y = pointsFlat[baseIdx + k * 2 + 1]
                    if !x.isNaN && !y.isNaN {
                        allNaN = false
                        break
                    }
                }

                // P408: Missing poses -> no instance
                if allNaN { continue }

                // Build points
                var coords = ContiguousArray<Float>(repeating: 0, count: K * 2)
                var vis = ContiguousArray<Bool>(repeating: false, count: K)
                var comp = ContiguousArray<Bool>(repeating: false, count: K)
                var scores = ContiguousArray<Float>(repeating: 0, count: K)

                for k in 0..<K {
                    let x = pointsFlat[baseIdx + k * 2]
                    let y = pointsFlat[baseIdx + k * 2 + 1]
                    coords[k * 2] = x
                    coords[k * 2 + 1] = y

                    let isFinite = !x.isNaN && !y.isNaN
                    vis[k] = isFinite
                    comp[k] = isFinite

                    if hasConfidence, let conf = confidenceFlat {
                        let confIdx = (t * N * K) + (n * K) + k
                        if confIdx < conf.count {
                            scores[k] = conf[confIdx]
                        }
                    }
                }

                let pointsArray = PointsArray(
                    coordinates: coords,
                    visibility: vis,
                    completeness: comp
                )

                if hasConfidence {
                    let predPoints = PredictedPointsArray(
                        pointsArray: pointsArray,
                        scores: scores
                    )
                    let meanScore = scores.reduce(Float(0), +) / Float(K)
                    let inst = PredictedInstance(
                        skeleton: skeleton,
                        points: predPoints,
                        score: meanScore,
                        track: tracks[n]
                    )
                    instances.append(inst)
                } else {
                    let inst = Instance(
                        skeleton: skeleton,
                        points: pointsArray,
                        track: tracks[n]
                    )
                    instances.append(inst)
                }
            }

            if !instances.isEmpty {
                let frame = LabeledFrame(
                    video: video,
                    frameIndex: t,
                    instances: instances
                )
                frames.append(frame)
            }
        }

        return Labels(
            frameStore: EagerFrameStore(frames: frames),
            videos: [video],
            skeletons: [skeleton],
            tracks: tracks
        )
    }

    // MARK: - Write

    /// Write a Labels object to a JABS HDF5 file.
    ///
    /// - Parameters:
    ///   - labels: The Labels to export.
    ///   - path: Output file path.
    ///   - config: Configuration (node names override).
    /// - Throws: `SleapIOError.unsupportedFormat` for multi-skeleton,
    ///           `SleapIOError.corruptData` if file cannot be created.
    public static func write(_ labels: Labels, to path: String, config: Config = Config()) throws {
        // J04: Single-skeleton only
        guard labels.skeletons.count <= 1 else {
            throw SleapIOError.unsupportedFormat(
                "JABS format supports only single-skeleton data, found \(labels.skeletons.count) skeletons")
        }

        guard let skeleton = labels.skeleton else {
            // No skeleton means no data to write — create empty file
            let file = try HDF5File.create(path: path)
            _ = try file.createGroup(name: "poseest")
            return
        }

        let K = skeleton.nodes.count

        // Collect all frames sorted by frame index
        let allFrames = labels.frameStore.allFrames().sorted { $0.frameIndex < $1.frameIndex }

        // Determine frame range
        guard !allFrames.isEmpty else {
            let file = try HDF5File.create(path: path)
            _ = try file.createGroup(name: "poseest")
            return
        }

        // Determine the max frame index to set T
        let maxFrameIdx = allFrames.map(\.frameIndex).max()!
        let T = maxFrameIdx + 1

        // Build deterministic track ordering
        let tracks = labels.tracks
        let N: Int

        if tracks.isEmpty {
            // Trackless data: verify no frame has multiple instances (would silently overwrite)
            let maxInstPerFrame = allFrames.map(\.instances.count).max() ?? 0
            if maxInstPerFrame > 1 {
                throw SleapIOError.unsupportedFormat(
                    "JABS export requires tracked instances when frames contain multiple animals. "
                    + "Found \(maxInstPerFrame) untracked instances in a single frame.")
            }
            N = 1
        } else {
            N = tracks.count
        }

        // Map track identity to index
        var trackIndex: [ObjectIdentifier: Int] = [:]
        for (i, track) in tracks.enumerated() {
            trackIndex[ObjectIdentifier(track)] = i
        }

        // Check if any predicted instances exist
        let hasPredictions = allFrames.contains { frame in
            frame.instances.contains { $0 is PredictedInstance }
        }

        // Allocate flat arrays initialized to NaN / 0
        var pointsFlat = [Float](repeating: Float.nan, count: T * N * K * 2)
        var confFlat: [Float]? = hasPredictions
            ? [Float](repeating: 0, count: T * N * K) : nil

        for frame in allFrames {
            let t = frame.frameIndex
            guard t >= 0 && t < T else { continue }

            for inst in frame.instances {
                // Determine animal slot
                let n: Int
                if let track = inst.track, let idx = trackIndex[ObjectIdentifier(track)] {
                    n = idx
                } else if tracks.isEmpty {
                    n = 0
                } else {
                    continue  // skip untracked instances in multi-track export
                }

                guard n < N else { continue }

                let baseIdx = (t * N * K * 2) + (n * K * 2)

                for k in 0..<min(K, inst.points.count) {
                    let x = inst.points.coordinates[k * 2]
                    let y = inst.points.coordinates[k * 2 + 1]
                    pointsFlat[baseIdx + k * 2] = x
                    pointsFlat[baseIdx + k * 2 + 1] = y

                    if confFlat != nil {
                        let confBase = (t * N * K) + (n * K)
                        if let pred = inst as? PredictedInstance {
                            confFlat![confBase + k] = pred.predictedPoints.scores[k]
                        } else if inst.points.visibility[k] {
                            confFlat![confBase + k] = 1.0
                        }
                    }
                }
            }
        }

        // Create HDF5 file
        let file: HDF5File
        do {
            file = try HDF5File.create(path: path)
        } catch {
            throw SleapIOError.corruptData("Cannot create HDF5 file: \(path)")
        }

        // Create poseest group
        let poseest = try file.createGroup(name: "poseest")

        // Write points dataset: (T, N, K, 2) float32
        let pointsSpace = try HDF5Dataspace.create(dims: [T, N, K, 2])
        let pointsType = try HDF5Datatype.copy(shim_H5T_NATIVE_FLOAT())
        let pointsDS = try poseest.createDataset(
            name: "points", type: pointsType, space: pointsSpace)
        try pointsDS.write(pointsFlat, memType: shim_H5T_NATIVE_FLOAT())

        // Write confidence dataset: (T, N, K) float32 — only if predictions exist
        if let conf = confFlat {
            let confSpace = try HDF5Dataspace.create(dims: [T, N, K])
            let confType = try HDF5Datatype.copy(shim_H5T_NATIVE_FLOAT())
            let confDS = try poseest.createDataset(
                name: "confidence", type: confType, space: confSpace)
            try confDS.write(conf, memType: shim_H5T_NATIVE_FLOAT())
        }

        // Write node_names attribute on root
        let nodeNames = config.nodeNames ?? skeleton.nodes.map(\.name)
        try writeStringArrayAttribute(to: file.id, name: "node_names", values: nodeNames)
    }

    // MARK: - Private helpers

    /// Read a string array attribute from an HDF5 object.
    private static func readStringArrayAttribute(from locId: hid_t, name: String) throws -> [String] {
        let aid = try hdf5Call("H5Aopen \(name)") {
            H5Aopen(locId, name, shim_H5P_DEFAULT())
        }
        defer { H5Aclose(aid) }

        let tid = H5Aget_type(aid)
        defer { H5Tclose(tid) }

        let space = H5Aget_space(aid)
        defer { H5Sclose(space) }

        // Get number of elements
        let ndims = H5Sget_simple_extent_ndims(space)
        var dims = [hsize_t](repeating: 0, count: Int(ndims))
        H5Sget_simple_extent_dims(space, &dims, nil)
        let count = dims.isEmpty ? 1 : dims.reduce(1, *)
        let n = Int(count)

        let isVarLen = H5Tis_variable_str(tid) > 0

        if isVarLen {
            let memType = try HDF5Datatype.copy(tid)
            var ptrs = [UnsafeMutablePointer<CChar>?](repeating: nil, count: n)
            try hdf5Check("H5Aread vlen string array") {
                H5Aread(aid, memType.id, &ptrs)
            }

            var result: [String] = []
            result.reserveCapacity(n)
            for ptr in ptrs {
                if let p = ptr {
                    result.append(String(cString: p))
                } else {
                    result.append("")
                }
            }

            // Reclaim vlen memory
            let reclaimSpace = H5Aget_space(aid)
            defer { H5Sclose(reclaimSpace) }
            H5Treclaim(memType.id, reclaimSpace, shim_H5P_DEFAULT(), &ptrs)

            return result
        } else {
            // Fixed-length strings
            let strSize = H5Tget_size(tid)
            var buffer = [UInt8](repeating: 0, count: n * strSize)
            try hdf5Check("H5Aread fixed string array") {
                H5Aread(aid, tid, &buffer)
            }

            var result: [String] = []
            result.reserveCapacity(n)
            for i in 0..<n {
                let start = i * strSize
                var end = start + strSize
                while end > start && buffer[end - 1] == 0 { end -= 1 }
                let str = String(bytes: buffer[start..<end], encoding: .utf8)
                    ?? String(bytes: buffer[start..<end], encoding: .ascii)
                    ?? ""
                result.append(str)
            }
            return result
        }
    }

    /// Write a string array attribute to an HDF5 object.
    private static func writeStringArrayAttribute(
        to locId: hid_t, name: String, values: [String]
    ) throws {
        let memType = try HDF5Datatype.createVariableLengthString()

        var dims = [hsize_t(values.count)]
        let space = try hdf5Call("H5Screate_simple") {
            H5Screate_simple(1, &dims, nil)
        }
        defer { H5Sclose(space) }

        // Delete existing attribute if present
        if H5Aexists(locId, name) > 0 {
            H5Adelete(locId, name)
        }

        let aid = try hdf5Call("H5Acreate2 \(name)") {
            H5Acreate2(locId, name, memType.id, space, shim_H5P_DEFAULT(), shim_H5P_DEFAULT())
        }
        defer { H5Aclose(aid) }

        let cStrings = values.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        try hdf5Check("H5Awrite string array") {
            H5Awrite(aid, memType.id, &ptrs)
        }
    }
}

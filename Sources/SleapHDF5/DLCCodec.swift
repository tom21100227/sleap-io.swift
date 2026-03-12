import Foundation
import CHDF5
import SleapIO

/// Codec for reading DeepLabCut HDF5 files (pandas HDFStore "fixed" format).
///
/// Supports single-animal and multi-animal DLC projects. Read-only — writing
/// is not supported and will throw `unsupportedFormat`.
public struct DLCCodec {

    // MARK: - Public API

    /// Read a DeepLabCut HDF5 file and return a `Labels` instance.
    ///
    /// - Parameter path: Path to the `.h5` file.
    /// - Returns: A fully-materialized `Labels` with `PredictedInstance`s.
    /// - Throws: `SleapIOError.fileNotFound`, `.unsupportedFormat`, or `.corruptData`.
    public static func read(from path: String) throws -> Labels {
        let file: HDF5File
        do {
            file = try HDF5File.openReadOnly(path: path)
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                throw SleapIOError.fileNotFound(path)
            }
            throw SleapIOError.corruptData("Cannot open HDF5 file: \(path)")
        }

        // Validate top-level structure
        guard file.exists(name: "df_with_missing") else {
            throw SleapIOError.unsupportedFormat(
                "DLC HDF5 file missing /df_with_missing group: \(path)")
        }

        let group = try file.openGroup(name: "df_with_missing")

        // Read the data matrix: (T, ncols) float64
        guard group.exists(name: "block0_values") else {
            throw SleapIOError.unsupportedFormat(
                "DLC HDF5 file missing block0_values dataset")
        }
        let valuesDS = try group.openDataset(name: "block0_values")
        let shape = valuesDS.shape
        guard shape.count == 2 else {
            throw SleapIOError.unsupportedFormat(
                "block0_values has unexpected rank \(shape.count), expected 2")
        }
        let numFrames = shape[0]
        let numCols = shape[1]
        let values = try valuesDS.readFloat64()

        // Read frame indices from axis1 (pandas fixed format: axis1 = row index = frame numbers)
        guard group.exists(name: "axis1") else {
            throw SleapIOError.unsupportedFormat("DLC HDF5 file missing axis1 dataset")
        }
        let axis1DS = try group.openDataset(name: "axis1")
        let frameIndices = try axis1DS.readInt64()
        guard frameIndices.count == numFrames else {
            throw SleapIOError.corruptData(
                "axis1 length (\(frameIndices.count)) != block0_values rows (\(numFrames))")
        }

        // Determine number of MultiIndex levels and prefix (axis0 vs block0_items)
        let (numLevels, indexPrefix) = detectIndexFormat(in: group)
        guard numLevels == 3 || numLevels == 4 else {
            throw SleapIOError.unsupportedFormat(
                "Expected 3 (single-animal) or 4 (multi-animal) MultiIndex levels, found \(numLevels)")
        }

        let isMultiAnimal = (numLevels == 4)

        // Read level arrays (string categories)
        let levels: [[String]] = try (0..<numLevels).map { i in
            try readLevelStrings(group: group, index: i, prefix: indexPrefix)
        }

        // Read label/code arrays (column-to-level mappings)
        let codes: [[Int]] = try (0..<numLevels).map { i in
            try readLabelCodes(group: group, index: i, prefix: indexPrefix)
        }

        // Validate all code arrays have length == numCols
        for (i, codeArr) in codes.enumerated() {
            guard codeArr.count == numCols else {
                throw SleapIOError.corruptData(
                    "label\(i) length (\(codeArr.count)) != numCols (\(numCols))")
            }
        }

        // Parse column structure
        let columns: [DLCColumn]
        if isMultiAnimal {
            columns = try parseMultiAnimalColumns(levels: levels, codes: codes, numCols: numCols)
        } else {
            columns = try parseSingleAnimalColumns(levels: levels, codes: codes, numCols: numCols)
        }

        // Extract unique bodypart names in column order
        var bodypartOrder: [String] = []
        var seenBodyparts = Set<String>()
        for col in columns {
            if !seenBodyparts.contains(col.bodypart) {
                bodypartOrder.append(col.bodypart)
                seenBodyparts.insert(col.bodypart)
            }
        }

        // Build skeleton (edgeless)
        let skeleton = Skeleton(name: "DLC")
        let nodes = bodypartOrder.map { name -> Node in
            let node = Node(name: name)
            skeleton.addNode(node)
            return node
        }
        let numNodes = nodes.count

        // Build bodypart-to-node-index map
        var bodypartToIdx: [String: Int] = [:]
        for (i, name) in bodypartOrder.enumerated() {
            bodypartToIdx[name] = i
        }

        // Group columns by (individual, bodypart) to find x/y/likelihood column indices
        // Key: (individual, bodypart) -> (xCol, yCol, likelihoodCol)
        var colMapping: [String: [String: [String: Int]]] = [:]  // individual -> bodypart -> coord -> colIdx
        for (colIdx, col) in columns.enumerated() {
            let individual = col.individual ?? ""
            if colMapping[individual] == nil {
                colMapping[individual] = [:]
            }
            if colMapping[individual]![col.bodypart] == nil {
                colMapping[individual]![col.bodypart] = [:]
            }
            colMapping[individual]![col.bodypart]![col.coord] = colIdx
        }

        // Determine individuals (preserving order from columns)
        var individualOrder: [String] = []
        var seenIndividuals = Set<String>()
        for col in columns {
            let ind = col.individual ?? ""
            if !seenIndividuals.contains(ind) {
                individualOrder.append(ind)
                seenIndividuals.insert(ind)
            }
        }

        // Build tracks for multi-animal
        var tracks: [Track] = []
        var individualToTrack: [String: Track] = [:]
        if isMultiAnimal {
            for ind in individualOrder {
                let track = Track(name: ind)
                tracks.append(track)
                individualToTrack[ind] = track
            }
        }

        // Create a dummy video for the source file
        let video = Video(filename: path, backendType: "hdf5")

        // Build frames
        var frames: [LabeledFrame] = []
        frames.reserveCapacity(numFrames)

        for t in 0..<numFrames {
            let frameIdx = Int(frameIndices[t])
            var instances: [Instance] = []

            for ind in individualOrder {
                guard let bpMap = colMapping[ind] else { continue }

                // Single pass: build points and check for data simultaneously
                var coords = ContiguousArray<Float>(repeating: Float.nan, count: numNodes * 2)
                var vis = ContiguousArray<Bool>(repeating: false, count: numNodes)
                var comp = ContiguousArray<Bool>(repeating: false, count: numNodes)
                var scores = ContiguousArray<Float>(repeating: 0, count: numNodes)
                var hasAnyData = false

                for bp in bodypartOrder {
                    guard let nodeIdx = bodypartToIdx[bp],
                          let coordMap = bpMap[bp] else { continue }

                    let xCol = coordMap["x"]
                    let yCol = coordMap["y"]
                    let lCol = coordMap["likelihood"]

                    let x: Double = xCol.map { values[t * numCols + $0] } ?? .nan
                    let y: Double = yCol.map { values[t * numCols + $0] } ?? .nan
                    let likelihood: Double = lCol.map { values[t * numCols + $0] } ?? 0.0

                    if !x.isNaN && !y.isNaN {
                        coords[nodeIdx * 2] = Float(x)
                        coords[nodeIdx * 2 + 1] = Float(y)
                        vis[nodeIdx] = true
                        comp[nodeIdx] = true
                        scores[nodeIdx] = Float(likelihood)
                        hasAnyData = true
                    }
                }

                guard hasAnyData else { continue }

                let pointsArray = PointsArray(
                    coordinates: coords,
                    visibility: vis,
                    completeness: comp
                )
                let predictedPoints = PredictedPointsArray(
                    pointsArray: pointsArray,
                    scores: scores
                )

                // Compute instance-level score as mean of visible point scores
                let visibleScores = (0..<numNodes).compactMap { vis[$0] ? scores[$0] : nil }
                let instanceScore = visibleScores.isEmpty ? 0.0 :
                    visibleScores.reduce(Float(0), +) / Float(visibleScores.count)

                let instance = PredictedInstance(
                    skeleton: skeleton,
                    points: predictedPoints,
                    score: instanceScore,
                    track: isMultiAnimal ? individualToTrack[ind] : nil
                )

                instances.append(instance)
            }

            // Skip frames with no instances (all individuals absent / all-NaN row)
            guard !instances.isEmpty else { continue }

            let frame = LabeledFrame(
                video: video,
                frameIndex: frameIdx,
                instances: instances
            )
            frames.append(frame)
        }

        return Labels(
            frameStore: EagerFrameStore(frames: frames),
            videos: [video],
            skeletons: [skeleton],
            tracks: tracks
        )
    }

    /// Writing DLC format is not supported.
    ///
    /// - Throws: `SleapIOError.unsupportedFormat` always.
    public static func write(_ labels: Labels, to path: String) throws {
        throw SleapIOError.unsupportedFormat("Writing DeepLabCut HDF5 format is not supported")
    }

    // MARK: - Private helpers

    /// A parsed column descriptor.
    private struct DLCColumn {
        let scorer: String
        let individual: String?  // nil for single-animal
        let bodypart: String
        let coord: String  // "x", "y", or "likelihood"
    }

    /// Detect MultiIndex format: count levels and determine prefix in one pass.
    private static func detectIndexFormat(in group: HDF5Group) -> (count: Int, prefix: String) {
        var count = 0
        // Try axis0_level* first (standard pandas fixed format)
        while group.exists(name: "axis0_level\(count)") {
            count += 1
        }
        if count > 0 { return (count, "axis0") }
        // Fallback: block0_items_level*
        while group.exists(name: "block0_items_level\(count)") {
            count += 1
        }
        if count > 0 { return (count, "block0_items") }
        return (0, "axis0")
    }

    /// Read string level values from column MultiIndex dataset.
    private static func readLevelStrings(group: HDF5Group, index: Int, prefix: String) throws -> [String] {
        let name = "\(prefix)_level\(index)"
        guard group.exists(name: name) else {
            throw SleapIOError.unsupportedFormat("Missing dataset \(name)")
        }
        let ds = try group.openDataset(name: name)
        return try ds.readVLenStrings()
    }

    /// Read integer code array from column MultiIndex dataset.
    private static func readLabelCodes(group: HDF5Group, index: Int, prefix: String) throws -> [Int] {
        let name = "\(prefix)_label\(index)"
        guard group.exists(name: name) else {
            throw SleapIOError.unsupportedFormat("Missing dataset \(name)")
        }
        let ds = try group.openDataset(name: name)
        // Keep the datatype wrapper alive while we read its size — ds.datatype
        // returns an owned wrapper that closes the HDF5 type on deinit.
        let dtype = ds.datatype
        let typeSize = H5Tget_size(dtype.id)

        // pandas writes codes as int8, int16, int32, or int64 depending on cardinality
        if typeSize <= 1 {
            // Read as uint8 (works for both int8 and uint8)
            let raw = try ds.readUInt8()
            return raw.map { Int(Int8(bitPattern: $0)) }
        } else if typeSize <= 2 {
            // int16 — read as int32 (HDF5 will convert)
            let raw = try ds.readInt32()
            return raw.map { Int($0) }
        } else if typeSize <= 4 {
            let raw = try ds.readInt32()
            return raw.map { Int($0) }
        } else {
            let raw = try ds.readInt64()
            return raw.map { Int($0) }
        }
    }

    /// Parse columns for single-animal DLC: (scorer, bodypart, coord).
    private static func parseSingleAnimalColumns(
        levels: [[String]], codes: [[Int]], numCols: Int
    ) throws -> [DLCColumn] {
        guard levels.count == 3 else {
            throw SleapIOError.unsupportedFormat("Single-animal requires 3 levels")
        }

        let scorerLevel = levels[0]
        let bodypartLevel = levels[1]
        let coordLevel = levels[2]

        var columns: [DLCColumn] = []
        columns.reserveCapacity(numCols)

        for c in 0..<numCols {
            let scorerIdx = codes[0][c]
            let bpIdx = codes[1][c]
            let coordIdx = codes[2][c]

            guard scorerIdx >= 0 && scorerIdx < scorerLevel.count,
                  bpIdx >= 0 && bpIdx < bodypartLevel.count,
                  coordIdx >= 0 && coordIdx < coordLevel.count else {
                throw SleapIOError.corruptData(
                    "Column \(c) has out-of-range code indices")
            }

            let coord = coordLevel[coordIdx]
            guard coord == "x" || coord == "y" || coord == "likelihood" else {
                throw SleapIOError.unsupportedFormat(
                    "Unexpected coordinate name '\(coord)' in column \(c)")
            }

            columns.append(DLCColumn(
                scorer: scorerLevel[scorerIdx],
                individual: nil,
                bodypart: bodypartLevel[bpIdx],
                coord: coord
            ))
        }

        return columns
    }

    /// Parse columns for multi-animal DLC: (scorer, individual, bodypart, coord).
    private static func parseMultiAnimalColumns(
        levels: [[String]], codes: [[Int]], numCols: Int
    ) throws -> [DLCColumn] {
        guard levels.count == 4 else {
            throw SleapIOError.unsupportedFormat("Multi-animal requires 4 levels")
        }

        let scorerLevel = levels[0]
        let individualLevel = levels[1]
        let bodypartLevel = levels[2]
        let coordLevel = levels[3]

        var columns: [DLCColumn] = []
        columns.reserveCapacity(numCols)

        for c in 0..<numCols {
            let scorerIdx = codes[0][c]
            let indIdx = codes[1][c]
            let bpIdx = codes[2][c]
            let coordIdx = codes[3][c]

            guard scorerIdx >= 0 && scorerIdx < scorerLevel.count,
                  indIdx >= 0 && indIdx < individualLevel.count,
                  bpIdx >= 0 && bpIdx < bodypartLevel.count,
                  coordIdx >= 0 && coordIdx < coordLevel.count else {
                throw SleapIOError.corruptData(
                    "Column \(c) has out-of-range code indices")
            }

            let coord = coordLevel[coordIdx]
            guard coord == "x" || coord == "y" || coord == "likelihood" else {
                throw SleapIOError.unsupportedFormat(
                    "Unexpected coordinate name '\(coord)' in column \(c)")
            }

            columns.append(DLCColumn(
                scorer: scorerLevel[scorerIdx],
                individual: individualLevel[indIdx],
                bodypart: bodypartLevel[bpIdx],
                coord: coord
            ))
        }

        return columns
    }
}

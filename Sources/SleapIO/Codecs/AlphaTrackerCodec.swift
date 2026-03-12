import Foundation

/// Read-only codec for AlphaTracker JSON pose data.
///
/// Supports the flat-array variant used by Python `sleap-io`:
/// each entry has `image_path`, `frame_index`, `animal_id`,
/// `keypoints` ([[x, y], ...]), and optional `confidence`.
///
/// There is no write method — AlphaTracker export is not supported.
public struct AlphaTrackerCodec {

    /// Configuration for AlphaTracker import.
    public struct Config {
        /// Explicit node names. If nil, defaults to node_0, node_1, ...
        public let nodeNames: [String]?

        public init(nodeNames: [String]? = nil) {
            self.nodeNames = nodeNames
        }
    }

    // MARK: - Read

    /// Read an AlphaTracker JSON file and return a fully materialized `Labels`.
    ///
    /// - Parameters:
    ///   - path: Path to the JSON file.
    ///   - config: Import configuration (optional node names).
    /// - Returns: An eagerly loaded `Labels` object.
    /// - Throws: `SleapIOError.fileNotFound` if the file does not exist,
    ///           `SleapIOError.corruptData` if JSON is malformed,
    ///           `SleapIOError.unsupportedFormat` if the schema is not supported.
    public static func read(from path: String, config: Config = Config()) throws -> Labels {
        // Read and parse JSON (handles fileNotFound + corruptData)
        let jsonObject = try CodecHelpers.readJSONFile(path)

        // Must be a top-level array of entry objects
        guard let entries = jsonObject as? [[String: Any]] else {
            throw SleapIOError.unsupportedFormat(
                "AlphaTracker JSON must be a top-level array of objects")
        }

        // Parse entries and validate schema
        var parsed: [ParsedEntry] = []
        for entry in entries {
            guard let imagePath = entry["image_path"] as? String,
                  let keypoints = entry["keypoints"] as? [[Any]],
                  entry["animal_id"] != nil else {
                throw SleapIOError.unsupportedFormat(
                    "AlphaTracker entries must have image_path, animal_id, and keypoints")
            }

            let frameIndex = CodecHelpers.intValue(entry["frame_index"]) ?? 0
            let animalID = CodecHelpers.intValue(entry["animal_id"]) ?? 0
            let confidence = CodecHelpers.doubleValue(entry["confidence"])

            // Parse keypoint coordinates
            var points: [(Float, Float)] = []
            for kp in keypoints {
                guard kp.count >= 2,
                      let x = CodecHelpers.doubleValue(kp[0]),
                      let y = CodecHelpers.doubleValue(kp[1]) else {
                    throw SleapIOError.corruptData(
                        "Invalid keypoint format: expected [x, y] arrays")
                }
                points.append((Float(x), Float(y)))
            }

            parsed.append(ParsedEntry(
                imagePath: imagePath,
                frameIndex: frameIndex,
                animalID: animalID,
                points: points,
                confidence: confidence
            ))
        }

        // Determine node count from first entry with keypoints
        let nodeCount: Int
        if let first = parsed.first {
            nodeCount = first.points.count
        } else {
            // Empty file -> empty labels
            return Labels()
        }

        // Build skeleton
        let names: [String]
        if let configNames = config.nodeNames {
            names = configNames
        } else {
            names = (0..<nodeCount).map { "node_\($0)" }
        }
        let nodes = names.map { Node(name: $0) }
        let skeleton = Skeleton(name: "Skeleton", nodes: nodes)

        // Build shared Track objects keyed by animal_id
        var tracksByAnimalID: [Int: Track] = [:]
        for entry in parsed {
            if tracksByAnimalID[entry.animalID] == nil {
                tracksByAnimalID[entry.animalID] = Track(name: "animal_\(entry.animalID)")
            }
        }

        // Build shared Video objects keyed by image_path
        var videosByPath: [String: Video] = [:]
        var videoOrder: [String] = []
        for entry in parsed {
            if videosByPath[entry.imagePath] == nil {
                videosByPath[entry.imagePath] = Video(filename: entry.imagePath)
                videoOrder.append(entry.imagePath)
            }
        }

        // Group entries by (image_path, frame_index) to preserve temporal structure.
        // A single image_path with multiple frame_index values produces separate frames.
        typealias FrameKey = String  // "imagePath\tframeIndex"
        var frameGroups: [FrameKey: [ParsedEntry]] = [:]
        var frameOrder: [FrameKey] = []
        for entry in parsed {
            let key = "\(entry.imagePath)\t\(entry.frameIndex)"
            if frameGroups[key] == nil {
                frameOrder.append(key)
            }
            frameGroups[key, default: []].append(entry)
        }

        var frames: [LabeledFrame] = []
        for key in frameOrder {
            guard let group = frameGroups[key], let first = group.first,
                  let video = videosByPath[first.imagePath] else { continue }

            var instances: [Instance] = []
            for entry in group {
                let track = tracksByAnimalID[entry.animalID]

                // Build points
                let pointStructs = entry.points.map { (x, y) in
                    Point(x: x, y: y, visible: true, complete: true)
                }

                if let confidence = entry.confidence {
                    // PredictedInstance
                    let predPoints = pointStructs.map { p in
                        PredictedPoint(point: p, score: 0.0)
                    }
                    let predArray = PredictedPointsArray(points: predPoints)
                    let inst = PredictedInstance(
                        skeleton: skeleton,
                        points: predArray,
                        score: Float(confidence),
                        track: track
                    )
                    instances.append(inst)
                } else {
                    // User Instance
                    let ptsArray = PointsArray(points: pointStructs)
                    let inst = Instance(
                        skeleton: skeleton,
                        points: ptsArray,
                        track: track
                    )
                    instances.append(inst)
                }
            }

            let frame = LabeledFrame(
                video: video,
                frameIndex: first.frameIndex,
                instances: instances
            )
            frames.append(frame)
        }

        // Collect identity tables in stable order
        let videos = videoOrder.compactMap { videosByPath[$0] }
        let tracks = tracksByAnimalID.sorted(by: { $0.key < $1.key }).map(\.value)

        let store = EagerFrameStore(frames: frames)
        return Labels(
            frameStore: store,
            videos: videos,
            skeletons: [skeleton],
            tracks: tracks
        )
    }

    // MARK: - Private types

    private struct ParsedEntry {
        let imagePath: String
        let frameIndex: Int
        let animalID: Int
        let points: [(Float, Float)]
        let confidence: Double?
    }
}

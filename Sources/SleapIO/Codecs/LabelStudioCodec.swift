import Foundation

/// Codec for reading/writing Label Studio keypoint JSON tasks.
///
/// Label Studio does not define enough information to reconstruct SLEAP skeleton
/// order and topology on its own. Both import and export require an explicit
/// `SkeletonMapping` that maps Label Studio keypoint labels to SLEAP node names.
public struct LabelStudioCodec {

    /// Maps Label Studio keypoint labels to SLEAP skeleton nodes.
    public struct SkeletonMapping {
        /// The target skeleton.
        public let skeleton: Skeleton
        /// Label Studio label string -> SLEAP node name.
        public let labelToNode: [String: String]

        public init(skeleton: Skeleton, labelToNode: [String: String]) {
            self.skeleton = skeleton
            self.labelToNode = labelToNode
        }
    }

    // MARK: - Read

    /// Read Label Studio keypoint JSON from a file path.
    ///
    /// - Parameters:
    ///   - path: Path to the Label Studio JSON file.
    ///   - mapping: Skeleton mapping from LS labels to node names.
    /// - Returns: A fully materialized `Labels` object.
    /// - Throws: `SleapIOError.fileNotFound` if the file does not exist,
    ///   `SleapIOError.corruptData` if the JSON is malformed or missing required fields,
    ///   `SleapIOError.invalidSkeleton` if the mapping is empty or inconsistent.
    public static func read(from path: String, mapping: SkeletonMapping) throws -> Labels {
        // LJS01: Validate mapping
        try validateMapping(mapping)

        // Read and parse JSON (handles fileNotFound + corruptData)
        let json = try CodecHelpers.readJSONFile(path)

        guard let tasks = json as? [[String: Any]] else {
            throw SleapIOError.corruptData("Expected JSON array of tasks")
        }

        let jsonDir = (path as NSString).deletingLastPathComponent

        // Build reverse mapping: node name -> node index
        let nodeNameToIndex: [String: Int] = {
            var map: [String: Int] = [:]
            for (i, node) in mapping.skeleton.nodes.enumerated() {
                map[node.name] = i
            }
            return map
        }()

        var videos: [Video] = []
        var frames: [LabeledFrame] = []

        for task in tasks {
            guard let dataDict = task["data"] as? [String: Any],
                  let imagePath = dataDict["image"] as? String else {
                continue
            }

            // LJS02: Resolve image path relative to JSON file
            let resolvedPath: String
            if imagePath.hasPrefix("/") {
                resolvedPath = imagePath
            } else {
                resolvedPath = (jsonDir as NSString).appendingPathComponent(imagePath)
            }

            let video = Video(filename: resolvedPath)
            videos.append(video)

            var instances: [Instance] = []

            // Process annotations (user instances)
            if let annotations = task["annotations"] as? [[String: Any]] {
                for annotation in annotations {
                    guard let results = annotation["result"] as? [[String: Any]] else { continue }
                    let parsed = try parseResults(
                        results, mapping: mapping, nodeNameToIndex: nodeNameToIndex,
                        isPredicted: false
                    )
                    instances.append(contentsOf: parsed)
                }
            }

            // Process predictions (predicted instances)
            if let predictions = task["predictions"] as? [[String: Any]] {
                for prediction in predictions {
                    guard let results = prediction["result"] as? [[String: Any]] else { continue }
                    let predScore = CodecHelpers.floatValue(prediction["score"]) ?? 0.0
                    let parsed = try parseResults(
                        results, mapping: mapping, nodeNameToIndex: nodeNameToIndex,
                        isPredicted: true, predictionScore: predScore
                    )
                    instances.append(contentsOf: parsed)
                }
            }

            let frame = LabeledFrame(video: video, frameIndex: 0, instances: instances)
            frames.append(frame)
        }

        // P02: Eager import
        let store = EagerFrameStore(frames: frames)
        return Labels(
            frameStore: store,
            videos: videos,
            skeletons: [mapping.skeleton],
            tracks: []
        )
    }

    // MARK: - Write

    /// Write Labels to Label Studio keypoint JSON format.
    ///
    /// - Parameters:
    ///   - labels: The labels to export.
    ///   - path: Output file path.
    ///   - mapping: Skeleton mapping from LS labels to node names.
    /// - Throws: `SleapIOError.invalidSkeleton` if the mapping is empty or inconsistent,
    ///   `SleapIOError.videoError` if image dimensions are unavailable.
    public static func write(_ labels: Labels, to path: String, mapping: SkeletonMapping) throws {
        try validateMapping(mapping)

        // Build reverse mapping: node name -> LS label
        var nodeToLabel: [String: String] = [:]
        for (lsLabel, nodeName) in mapping.labelToNode {
            nodeToLabel[nodeName] = lsLabel
        }

        var tasks: [[String: Any]] = []

        for i in 0..<labels.frameStore.count {
            let frame = labels.frameStore.frame(at: i)
            let video = frame.video

            guard let frameSize = video.frameSize else {
                throw SleapIOError.videoError(
                    "Cannot export to Label Studio without known image dimensions for video: \(video.filename)"
                )
            }

            let width = Double(frameSize.width)
            let height = Double(frameSize.height)

            // Extract just the filename for data.image
            let imageName = (video.filename as NSString).lastPathComponent

            var annotationResults: [[String: Any]] = []
            var predictionResults: [[String: Any]] = []

            for (instIdx, inst) in frame.instances.enumerated() {
                let isPredicted = inst is PredictedInstance
                var instResults: [[String: Any]] = []
                let parentID = "inst_\(instIdx)"

                for nodeIdx in 0..<mapping.skeleton.nodes.count {
                    let node = mapping.skeleton.nodes[nodeIdx]
                    guard let lsLabel = nodeToLabel[node.name] else { continue }

                    let pt = inst.points[nodeIdx]
                    // Skip missing/NaN points — they can't be represented in LS JSON
                    guard !pt.x.isNaN && !pt.y.isNaN else { continue }

                    let xPct = Double(pt.x) / width * 100.0
                    let yPct = Double(pt.y) / height * 100.0

                    let value: [String: Any] = [
                        "x": xPct,
                        "y": yPct,
                        "keypointlabels": [lsLabel],
                        "original_width": Int(width),
                        "original_height": Int(height),
                    ]

                    let result: [String: Any] = [
                        "id": "kp_\(instIdx)_\(nodeIdx)",
                        "type": "keypointlabels",
                        "parentID": parentID,
                        "value": value,
                        "original_width": Int(width),
                        "original_height": Int(height),
                    ]
                    instResults.append(result)
                }

                if isPredicted {
                    predictionResults.append(contentsOf: instResults)
                } else {
                    annotationResults.append(contentsOf: instResults)
                }
            }

            var task: [String: Any] = [
                "id": i + 1,
                "data": ["image": imageName],
            ]

            if !annotationResults.isEmpty {
                task["annotations"] = [
                    ["id": "ann_\(i)", "result": annotationResults]
                ]
            } else {
                task["annotations"] = [
                    ["id": "ann_\(i)", "result": [] as [[String: Any]]]
                ]
            }

            if !predictionResults.isEmpty {
                task["predictions"] = [
                    ["id": "pred_\(i)", "result": predictionResults]
                ]
            }

            tasks.append(task)
        }

        let jsonData = try JSONSerialization.data(withJSONObject: tasks, options: [.prettyPrinted])
        try jsonData.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Private helpers

    /// Validate the skeleton mapping.
    private static func validateMapping(_ mapping: SkeletonMapping) throws {
        // Empty mapping -> invalidSkeleton
        guard !mapping.labelToNode.isEmpty else {
            throw SleapIOError.invalidSkeleton("Label Studio mapping must not be empty")
        }

        // Every mapped node name must exist in the skeleton
        for (lsLabel, nodeName) in mapping.labelToNode {
            guard mapping.skeleton.node(named: nodeName) != nil else {
                throw SleapIOError.invalidSkeleton(
                    "Mapping label '\(lsLabel)' -> node '\(nodeName)' but skeleton has no node named '\(nodeName)'"
                )
            }
        }
    }

    /// Parse keypoint results from an annotation or prediction into instances.
    ///
    /// Groups results by `parentID` when present, otherwise by the result's own `id`.
    private static func parseResults(
        _ results: [[String: Any]],
        mapping: SkeletonMapping,
        nodeNameToIndex: [String: Int],
        isPredicted: Bool,
        predictionScore: Float = 0.0
    ) throws -> [Instance] {
        // Filter to keypoint results only
        let keypointResults = results.filter { ($0["type"] as? String) == "keypointlabels" }

        // LJS03: Group by parentID when present, otherwise by own id
        var groups: [String: [[String: Any]]] = [:]
        var groupOrder: [String] = []

        for result in keypointResults {
            let groupKey: String
            if let parentID = result["parentID"] as? String {
                groupKey = parentID
            } else {
                groupKey = (result["id"] as? String) ?? UUID().uuidString
            }

            if groups[groupKey] == nil {
                groupOrder.append(groupKey)
            }
            groups[groupKey, default: []].append(result)
        }

        var instances: [Instance] = []

        for groupKey in groupOrder {
            guard let groupResults = groups[groupKey] else { continue }

            // Initialize points as NaN/invisible
            var points = [Point](repeating: Point(x: .nan, y: .nan, visible: false, complete: false),
                                 count: mapping.skeleton.nodes.count)

            for result in groupResults {
                guard let value = result["value"] as? [String: Any] else { continue }
                guard let labels = value["keypointlabels"] as? [String], let lsLabel = labels.first else {
                    continue
                }

                // Map LS label to node name
                guard let nodeName = mapping.labelToNode[lsLabel] else {
                    // Unmapped labels are skipped
                    continue
                }
                guard let nodeIdx = nodeNameToIndex[nodeName] else { continue }

                // LJS04: Get coordinates (percentage-based)
                guard let xPct = CodecHelpers.doubleValue(value["x"]),
                      let yPct = CodecHelpers.doubleValue(value["y"]) else {
                    continue
                }

                // Get original dimensions - check both result level and value level
                let origWidth: Double
                let origHeight: Double

                if let w = CodecHelpers.doubleValue(value["original_width"]),
                   let h = CodecHelpers.doubleValue(value["original_height"]) {
                    origWidth = w
                    origHeight = h
                } else if let w = CodecHelpers.doubleValue(result["original_width"]),
                          let h = CodecHelpers.doubleValue(result["original_height"]) {
                    origWidth = w
                    origHeight = h
                } else {
                    throw SleapIOError.corruptData(
                        "Missing original_width/original_height for keypoint result"
                    )
                }

                let absX = Float(xPct / 100.0 * origWidth)
                let absY = Float(yPct / 100.0 * origHeight)

                points[nodeIdx] = Point(x: absX, y: absY, visible: true, complete: true)
            }

            let pointsArray = PointsArray(points: points)

            if isPredicted {
                let predPoints = PredictedPointsArray(
                    pointsArray: pointsArray,
                    scores: ContiguousArray(repeating: 0.0, count: points.count)
                )
                let inst = PredictedInstance(
                    skeleton: mapping.skeleton,
                    points: predPoints,
                    score: predictionScore
                )
                instances.append(inst)
            } else {
                let inst = Instance(skeleton: mapping.skeleton, points: pointsArray)
                instances.append(inst)
            }
        }

        return instances
    }
}

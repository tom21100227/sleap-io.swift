import Foundation

/// Codec for reading and writing COCO keypoints JSON format.
///
/// Supports the standard COCO keypoints schema with top-level `images`,
/// `annotations`, and `categories` arrays. See PHASE3_SPEC.md sections C01-C07.
public struct COCOCodec {

    // MARK: - Read

    /// Read a COCO keypoints JSON file and return a Labels object.
    ///
    /// - Parameter path: Path to the COCO JSON file.
    /// - Returns: A fully materialized (eager) Labels object.
    /// - Throws: `SleapIOError.fileNotFound` if the file does not exist,
    ///   `SleapIOError.corruptData` if the JSON is malformed or has invalid references.
    public static func read(from path: String) throws -> Labels {
        // Read and parse JSON (handles fileNotFound + corruptData)
        let jsonObject = try CodecHelpers.readJSONFile(path)

        guard let root = jsonObject as? [String: Any] else {
            throw SleapIOError.corruptData("Root JSON object is not a dictionary")
        }

        // Parse categories → skeletons (C01)
        let categoryDicts = root["categories"] as? [[String: Any]] ?? []
        var skeletonByCategoryID: [Int: Skeleton] = [:]
        var skeletonsOrdered: [Skeleton] = []

        for catDict in categoryDicts {
            guard let catID = CodecHelpers.intValue(catDict["id"]) else {
                throw SleapIOError.corruptData("Category missing 'id'")
            }
            let name = catDict["name"] as? String ?? "category_\(catID)"
            let keypointNames = catDict["keypoints"] as? [String] ?? []

            let nodes = keypointNames.map { Node(name: $0) }

            var edges: [Edge] = []
            if let skeletonPairs = catDict["skeleton"] as? [[Any]] {
                for pair in skeletonPairs {
                    guard pair.count == 2,
                          let srcIdx = CodecHelpers.intValue(pair[0]),
                          let dstIdx = CodecHelpers.intValue(pair[1]) else { continue }
                    // COCO skeleton uses 1-based indices
                    let src1 = srcIdx - 1
                    let dst1 = dstIdx - 1
                    guard src1 >= 0, src1 < nodes.count,
                          dst1 >= 0, dst1 < nodes.count else { continue }
                    edges.append(Edge(source: nodes[src1], destination: nodes[dst1]))
                }
            }

            let skeleton = Skeleton(name: name, nodes: nodes, edges: edges)
            skeletonByCategoryID[catID] = skeleton
            skeletonsOrdered.append(skeleton)
        }

        // Parse images → videos and frames (C02)
        let imageDicts = root["images"] as? [[String: Any]] ?? []
        var videoByImageID: [Int: Video] = [:]
        var frameByImageID: [Int: LabeledFrame] = [:]
        var videosOrdered: [Video] = []
        var framesOrdered: [LabeledFrame] = []

        for imgDict in imageDicts {
            guard let imgID = CodecHelpers.intValue(imgDict["id"]) else {
                throw SleapIOError.corruptData("Image missing 'id'")
            }
            let fileName = imgDict["file_name"] as? String ?? "unknown_\(imgID)"

            let video = Video(filename: fileName)

            // Set frameSize if width/height present
            if let width = CodecHelpers.intValue(imgDict["width"]),
               let height = CodecHelpers.intValue(imgDict["height"]) {
                video.frameSize = (height: height, width: width, channels: 3)
            }

            let frame = LabeledFrame(video: video, frameIndex: 0)

            videoByImageID[imgID] = video
            frameByImageID[imgID] = frame
            videosOrdered.append(video)
            framesOrdered.append(frame)
        }

        // Parse annotations → instances (C03, C04)
        let annotationDicts = root["annotations"] as? [[String: Any]] ?? []

        for annDict in annotationDicts {
            guard let imageID = CodecHelpers.intValue(annDict["image_id"]) else {
                throw SleapIOError.corruptData("Annotation missing 'image_id'")
            }
            guard let categoryID = CodecHelpers.intValue(annDict["category_id"]) else {
                throw SleapIOError.corruptData("Annotation missing 'category_id'")
            }

            // P06: missing references → corruptData
            guard let frame = frameByImageID[imageID] else {
                throw SleapIOError.corruptData("Annotation references nonexistent image_id \(imageID)")
            }
            guard let skeleton = skeletonByCategoryID[categoryID] else {
                throw SleapIOError.corruptData("Annotation references nonexistent category_id \(categoryID)")
            }

            // Parse keypoints
            guard let keypointsRaw = annDict["keypoints"] as? [Any] else {
                throw SleapIOError.corruptData("Annotation missing 'keypoints'")
            }

            let nodeCount = skeleton.nodes.count
            guard keypointsRaw.count == nodeCount * 3 else {
                throw SleapIOError.corruptData(
                    "Keypoints array length \(keypointsRaw.count) != 3 * \(nodeCount) for category \(categoryID)")
            }

            // Convert keypoints to numbers
            let keypoints: [Double] = keypointsRaw.map { CodecHelpers.doubleValue($0) ?? 0.0 }

            // Build points (C04)
            var points: [Point] = []
            points.reserveCapacity(nodeCount)
            for i in 0..<nodeCount {
                let x = keypoints[i * 3]
                let y = keypoints[i * 3 + 1]
                let v = Int(keypoints[i * 3 + 2])

                let point: Point
                if v == 0 {
                    point = Point(x: .nan, y: .nan, visible: false, complete: false)
                } else if v == 1 {
                    point = Point(x: Float(x), y: Float(y), visible: false, complete: true)
                } else {
                    // v >= 2
                    point = Point(x: Float(x), y: Float(y), visible: true, complete: true)
                }
                points.append(point)
            }

            let pointsArray = PointsArray(points: points)

            // C03: score presence determines Instance vs PredictedInstance
            let instance: Instance
            if let scoreNum = annDict["score"], let scoreVal = CodecHelpers.doubleValue(scoreNum) {
                let predPoints = PredictedPointsArray(
                    pointsArray: pointsArray,
                    scores: ContiguousArray(repeating: Float(0.0), count: nodeCount)
                )
                instance = PredictedInstance(
                    skeleton: skeleton, points: predPoints, score: Float(scoreVal))
            } else {
                instance = Instance(skeleton: skeleton, points: pointsArray)
            }

            frame.instances.append(instance)
        }

        // Build Labels (P02: eager)
        let store = EagerFrameStore(frames: framesOrdered)
        return Labels(
            frameStore: store,
            videos: videosOrdered,
            skeletons: skeletonsOrdered,
            tracks: []
        )
    }

    // MARK: - Write

    /// Write a Labels object to a COCO keypoints JSON file.
    ///
    /// - Parameters:
    ///   - labels: The Labels object to export.
    ///   - path: Output file path.
    /// - Throws: `SleapIOError.videoError` if frame dimensions are unavailable.
    public static func write(_ labels: Labels, to path: String) throws {
        // Auto-materialize if lazy (no-ops when eager)
        labels.materialize()

        // Build skeleton → category ID map (1-based, C05)
        var skelToCatID: [ObjectIdentifier: Int] = [:]
        for (i, skel) in labels.skeletons.enumerated() {
            skelToCatID[ObjectIdentifier(skel)] = i + 1
        }

        // Build categories array
        var categories: [[String: Any]] = []
        for (i, skel) in labels.skeletons.enumerated() {
            var cat: [String: Any] = [:]
            cat["id"] = i + 1
            cat["name"] = skel.name
            cat["keypoints"] = skel.nodes.map(\.name)
            cat["supercategory"] = skel.name

            // Edges as 1-based pairs
            var skeletonEdges: [[Int]] = []
            for edge in skel.edges {
                if let srcIdx = skel.index(of: edge.source),
                   let dstIdx = skel.index(of: edge.destination) {
                    skeletonEdges.append([srcIdx + 1, dstIdx + 1])
                }
            }
            cat["skeleton"] = skeletonEdges

            categories.append(cat)
        }

        // Build images and annotations
        var images: [[String: Any]] = []
        var annotations: [[String: Any]] = []
        var imageID = 1
        var annotationID = 1

        for i in 0..<labels.frameStore.count {
            let frame = labels.frameStore.frame(at: i)
            let video = frame.video

            // C06: require frame dimensions
            guard let frameSize = video.frameSize else {
                throw SleapIOError.videoError(
                    "Cannot export to COCO: video '\(video.filename)' has no frameSize")
            }

            var imgDict: [String: Any] = [:]
            imgDict["id"] = imageID
            imgDict["file_name"] = video.filename
            imgDict["width"] = frameSize.width
            imgDict["height"] = frameSize.height
            images.append(imgDict)

            // One annotation per instance (C05)
            for inst in frame.instances {
                guard let catID = skelToCatID[ObjectIdentifier(inst.skeleton)] else { continue }

                var annDict: [String: Any] = [:]
                annDict["id"] = annotationID
                annDict["image_id"] = imageID
                annDict["category_id"] = catID
                annDict["iscrowd"] = 0

                // Build keypoints array and compute bbox (C05)
                let nodeCount = inst.points.count
                var kps = [Double]()
                kps.reserveCapacity(nodeCount * 3)
                var numKeypoints = 0
                var minX = Float.greatestFiniteMagnitude
                var minY = Float.greatestFiniteMagnitude
                var maxX = -Float.greatestFiniteMagnitude
                var maxY = -Float.greatestFiniteMagnitude
                var hasFinite = false

                for j in 0..<nodeCount {
                    let pt = inst.points[j]
                    let x = pt.x
                    let y = pt.y

                    if x.isNaN || y.isNaN {
                        // v=0, emit 0,0
                        kps.append(0.0)
                        kps.append(0.0)
                        kps.append(0.0)
                    } else if pt.visible {
                        // v=2
                        kps.append(Double(x))
                        kps.append(Double(y))
                        kps.append(2.0)
                        numKeypoints += 1
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                        hasFinite = true
                    } else {
                        // v=1 (finite but not visible)
                        kps.append(Double(x))
                        kps.append(Double(y))
                        kps.append(1.0)
                        numKeypoints += 1
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                        hasFinite = true
                    }
                }

                annDict["keypoints"] = kps
                annDict["num_keypoints"] = numKeypoints

                // bbox = [x, y, width, height] from finite coords
                let bboxX: Double
                let bboxY: Double
                let bboxW: Double
                let bboxH: Double
                if hasFinite {
                    bboxX = Double(minX)
                    bboxY = Double(minY)
                    bboxW = Double(maxX - minX)
                    bboxH = Double(maxY - minY)
                } else {
                    bboxX = 0; bboxY = 0; bboxW = 0; bboxH = 0
                }
                annDict["bbox"] = [bboxX, bboxY, bboxW, bboxH]
                annDict["area"] = bboxW * bboxH

                // C05: score for PredictedInstance
                if let predicted = inst as? PredictedInstance {
                    annDict["score"] = Double(predicted.score)
                }

                annotations.append(annDict)
                annotationID += 1
            }

            imageID += 1
        }

        // Build output dictionary
        let output: [String: Any] = [
            "categories": categories,
            "images": images,
            "annotations": annotations,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

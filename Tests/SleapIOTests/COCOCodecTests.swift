import XCTest
@testable import SleapIO

/// COCO JSON codec tests (C01-C07, P02, P04, P06).
final class COCOCodecTests: XCTestCase {

    // MARK: - Helpers

    /// Resolve a fixture path under Tests/Fixtures/phase3/.
    private func fixturePath(_ name: String) -> String {
        let testFile = URL(fileURLWithPath: #file)
        let fixturesDir = testFile
            .deletingLastPathComponent()           // SleapIOTests/
            .deletingLastPathComponent()           // Tests/
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("phase3")
        return fixturesDir.appendingPathComponent(name).path
    }

    /// Create a temporary file path for write tests.
    private func temporaryPath(_ name: String) -> String {
        NSTemporaryDirectory() + "/" + UUID().uuidString + "_" + name
    }

    /// Build a minimal COCO JSON string and write it to a temp file, returning the path.
    @discardableResult
    private func writeTempCOCO(_ json: String, name: String = "test.json") -> String {
        let path = temporaryPath(name)
        try! json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Build a minimal Labels with one skeleton, one video, one frame, one instance.
    private func makeSimpleLabels(
        skeletonName: String = "animal",
        nodeNames: [String] = ["head", "body", "tail"],
        edges: [(Int, Int)] = [(0, 1), (1, 2)],
        videoFilename: String = "image001.jpg",
        frameSize: (height: Int, width: Int, channels: Int)? = (height: 480, width: 640, channels: 3),
        points: [Point],
        predicted: Bool = false,
        score: Float = 0.0,
        track: Track? = nil
    ) -> Labels {
        let nodes = nodeNames.map { Node(name: $0) }
        let skeleton = Skeleton(
            name: skeletonName,
            nodes: nodes,
            edges: edges.map { Edge(source: nodes[$0.0], destination: nodes[$0.1]) }
        )

        let video = Video(filename: videoFilename)
        video.frameSize = frameSize

        let pointsArray = PointsArray(points: points)

        let instance: Instance
        if predicted {
            let predPoints = PredictedPointsArray(
                pointsArray: pointsArray,
                scores: ContiguousArray(repeating: Float(0.9), count: points.count)
            )
            instance = PredictedInstance(skeleton: skeleton, points: predPoints, score: score, track: track)
        } else {
            instance = Instance(skeleton: skeleton, points: pointsArray, track: track)
        }

        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [instance])
        let store = EagerFrameStore(frames: [frame])
        return Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: track.map { [$0] } ?? []
        )
    }

    /// Build a COCO JSON dictionary as a string.
    private func cocoJSON(
        categories: [[String: Any]] = [],
        images: [[String: Any]] = [],
        annotations: [[String: Any]] = []
    ) -> String {
        let dict: [String: Any] = [
            "categories": categories,
            "images": images,
            "annotations": annotations,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - C01: Category to skeleton mapping

    func testSingleCategoryImportsSkeleton() throws {
        // C01: single category → one Skeleton with correct name, nodes, edges
        let json = cocoJSON(
            categories: [
                [
                    "id": 1,
                    "name": "fly",
                    "keypoints": ["head", "thorax", "abdomen"],
                    "skeleton": [[1, 2], [2, 3]],  // 1-based
                ],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 640, "height": 480],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [100.0, 200.0, 2, 150.0, 250.0, 2, 200.0, 300.0, 2],
                    "bbox": [100, 200, 100, 100], "area": 10000, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels.skeletons.count, 1)
        let skeleton = labels.skeletons[0]
        XCTAssertEqual(skeleton.name, "fly")
        XCTAssertEqual(skeleton.nodes.count, 3)
        XCTAssertEqual(skeleton.nodes.map(\.name), ["head", "thorax", "abdomen"])
        XCTAssertEqual(skeleton.edges.count, 2)
    }

    func testCategoryWithoutEdges() throws {
        // C01: category with no `skeleton` key → 0 edges
        let json = cocoJSON(
            categories: [
                [
                    "id": 1,
                    "name": "blob",
                    "keypoints": ["center", "tip"],
                ],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2, 30.0, 40.0, 2],
                    "bbox": [10, 20, 20, 20], "area": 400, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.skeletons[0].nodes.count, 2)
        XCTAssertTrue(labels.skeletons[0].edges.isEmpty)
    }

    func testMultipleCategoriesCreateMultipleSkeletons() throws {
        // C01: 2 categories → 2 distinct Skeleton objects
        let json = cocoJSON(
            categories: [
                [
                    "id": 1, "name": "fly",
                    "keypoints": ["head", "thorax"],
                    "skeleton": [[1, 2]],
                ],
                [
                    "id": 2, "name": "mouse",
                    "keypoints": ["nose", "ear_left", "ear_right", "tail"],
                    "skeleton": [[1, 2], [1, 3]],
                ],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 640, "height": 480],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2, 30.0, 40.0, 2],
                    "bbox": [10, 20, 20, 20], "area": 400, "iscrowd": 0,
                ],
                [
                    "id": 2, "image_id": 1, "category_id": 2,
                    "keypoints": [50.0, 60.0, 2, 70.0, 80.0, 2, 90.0, 100.0, 2, 110.0, 120.0, 2],
                    "bbox": [50, 60, 60, 60], "area": 3600, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels.skeletons.count, 2)
        XCTAssertFalse(labels.skeletons[0] === labels.skeletons[1])
        XCTAssertEqual(labels.skeletons[0].name, "fly")
        XCTAssertEqual(labels.skeletons[1].name, "mouse")
        XCTAssertEqual(labels.skeletons[0].nodes.count, 2)
        XCTAssertEqual(labels.skeletons[1].nodes.count, 4)
    }

    // MARK: - C02: Image to frame mapping

    func testImageCreatesVideoAndFrame() throws {
        // C02: each image → 1 Video + 1 LabeledFrame with frameIndex==0
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["pt"]],
            ],
            images: [
                ["id": 1, "file_name": "frame_001.jpg", "width": 320, "height": 240],
                ["id": 2, "file_name": "frame_002.jpg", "width": 320, "height": 240],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2],
                    "bbox": [10, 20, 0, 0], "area": 0, "iscrowd": 0,
                ],
                [
                    "id": 2, "image_id": 2, "category_id": 1,
                    "keypoints": [30.0, 40.0, 2],
                    "bbox": [30, 40, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels.videos.count, 2)
        XCTAssertEqual(labels.frameCount, 2)
        for i in 0..<labels.frameCount {
            XCTAssertEqual(labels[i].frameIndex, 0)
        }
    }

    func testImageWidthHeightPopulatesFrameSize() throws {
        // C02: width/height from image object populate video.frameSize
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["pt"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 1920, "height": 1080],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2],
                    "bbox": [10, 20, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        let video = labels.videos[0]
        XCTAssertNotNil(video.frameSize)
        XCTAssertEqual(video.frameSize?.width, 1920)
        XCTAssertEqual(video.frameSize?.height, 1080)
    }

    func testImageFilenameResolved() throws {
        // C02: Video.filename matches image file_name
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["pt"]],
            ],
            images: [
                ["id": 1, "file_name": "data/images/frame_042.png", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [5.0, 5.0, 2],
                    "bbox": [5, 5, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels.videos[0].filename, "data/images/frame_042.png")
    }

    // MARK: - C03: Annotation to instance mapping

    func testAnnotationCreatesInstance() throws {
        // C03: annotation without score → Instance (not PredictedInstance)
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head", "tail"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2, 30.0, 40.0, 2],
                    "bbox": [10, 20, 20, 20], "area": 400, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels[0].instances.count, 1)
        let inst = labels[0].instances[0]
        XCTAssertFalse(inst is PredictedInstance, "Annotation without score should be Instance, not PredictedInstance")
    }

    func testAnnotationWithScoreCreatesPredictedInstance() throws {
        // C03: annotation with numeric score → PredictedInstance
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head", "tail"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2, 30.0, 40.0, 2],
                    "score": 0.87,
                    "bbox": [10, 20, 20, 20], "area": 400, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        let inst = labels[0].instances[0]
        XCTAssertTrue(inst is PredictedInstance, "Annotation with score should be PredictedInstance")
        let predicted = inst as! PredictedInstance
        XCTAssertEqual(predicted.score, 0.87, accuracy: 1e-4)
    }

    func testAnnotationLinksToCorrectFrame() throws {
        // C03: annotation's image_id maps to correct LabeledFrame
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["pt"]],
            ],
            images: [
                ["id": 10, "file_name": "a.jpg", "width": 100, "height": 100],
                ["id": 20, "file_name": "b.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 20, "category_id": 1,
                    "keypoints": [5.0, 5.0, 2],
                    "bbox": [5, 5, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        // Image with id 20 → "b.jpg"
        // The frame containing the annotation should reference "b.jpg"
        let frameWithAnnotation = labels.first { !$0.instances.isEmpty }
        XCTAssertNotNil(frameWithAnnotation)
        XCTAssertEqual(frameWithAnnotation?.video.filename, "b.jpg")
    }

    func testAnnotationLinksToCorrectSkeleton() throws {
        // C03: annotation's category_id maps to correct Skeleton
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "fly", "keypoints": ["head", "thorax"]],
                ["id": 2, "name": "mouse", "keypoints": ["nose", "tail"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 2,
                    "keypoints": [10.0, 20.0, 2, 30.0, 40.0, 2],
                    "bbox": [10, 20, 20, 20], "area": 400, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        let inst = labels[0].instances[0]
        XCTAssertEqual(inst.skeleton.name, "mouse")
    }

    // MARK: - C04: Keypoint visibility mapping

    func testVisibilityZeroImportsAsNaN() throws {
        // C04: v==0 → coordinates are NaN, visible==false, complete==false
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head", "tail"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [0.0, 0.0, 0, 30.0, 40.0, 2],
                    "bbox": [30, 40, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        let pt0 = labels[0].instances[0].points[0]
        XCTAssertTrue(pt0.x.isNaN, "v==0 should produce NaN x")
        XCTAssertTrue(pt0.y.isNaN, "v==0 should produce NaN y")
        XCTAssertFalse(pt0.visible)
        XCTAssertFalse(pt0.complete)
    }

    func testVisibilityOneImportsAsOccluded() throws {
        // C04: v==1 → coordinates preserved, visible==false, complete==true
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [55.0, 66.0, 1],
                    "bbox": [55, 66, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        let pt = labels[0].instances[0].points[0]
        XCTAssertEqual(pt.x, 55.0, accuracy: 1e-4)
        XCTAssertEqual(pt.y, 66.0, accuracy: 1e-4)
        XCTAssertFalse(pt.visible)
        XCTAssertTrue(pt.complete)
    }

    func testVisibilityTwoImportsAsVisible() throws {
        // C04: v>=2 → coordinates preserved, visible==true, complete==true
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [77.0, 88.0, 2],
                    "bbox": [77, 88, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        let pt = labels[0].instances[0].points[0]
        XCTAssertEqual(pt.x, 77.0, accuracy: 1e-4)
        XCTAssertEqual(pt.y, 88.0, accuracy: 1e-4)
        XCTAssertTrue(pt.visible)
        XCTAssertTrue(pt.complete)
    }

    func testWrongKeypointCountThrows() throws {
        // C04: keypoints array length != 3*nodeCount → throws corruptData
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head", "tail"]],  // 2 nodes → expect 6 values
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2, 30.0],  // only 4 values, not 6
                    "bbox": [10, 20, 20, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try COCOCodec.read(from: path)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    // MARK: - C05: COCO export behavior

    func testExportCategoryIDs() throws {
        // C05: category IDs are 1-based and stable
        let labels = makeSimpleLabels(
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),
                Point(x: 30, y: 40, visible: true, complete: true),
                Point(x: 50, y: 60, visible: true, complete: true),
            ]
        )

        let path = temporaryPath("export_catids.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let categories = parsed["categories"] as! [[String: Any]]

        XCTAssertEqual(categories.count, 1)
        XCTAssertEqual(categories[0]["id"] as? Int, 1, "Category IDs should be 1-based")
    }

    func testExportKeypointOrder() throws {
        // C05: keypoints emitted in skeleton node order
        let labels = makeSimpleLabels(
            nodeNames: ["alpha", "beta", "gamma"],
            edges: [],
            points: [
                Point(x: 1, y: 2, visible: true, complete: true),
                Point(x: 3, y: 4, visible: true, complete: true),
                Point(x: 5, y: 6, visible: true, complete: true),
            ]
        )

        let path = temporaryPath("export_order.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let categories = parsed["categories"] as! [[String: Any]]
        let annotations = parsed["annotations"] as! [[String: Any]]

        // Verify keypoint names in category are in skeleton node order
        let kpNames = categories[0]["keypoints"] as! [String]
        XCTAssertEqual(kpNames, ["alpha", "beta", "gamma"])

        // Verify keypoint coordinates in annotation match node order
        let kps = annotations[0]["keypoints"] as! [NSNumber]
        XCTAssertEqual(kps[0].floatValue, 1.0, accuracy: 1e-4)  // alpha.x
        XCTAssertEqual(kps[1].floatValue, 2.0, accuracy: 1e-4)  // alpha.y
        XCTAssertEqual(kps[3].floatValue, 3.0, accuracy: 1e-4)  // beta.x
        XCTAssertEqual(kps[4].floatValue, 4.0, accuracy: 1e-4)  // beta.y
        XCTAssertEqual(kps[6].floatValue, 5.0, accuracy: 1e-4)  // gamma.x
        XCTAssertEqual(kps[7].floatValue, 6.0, accuracy: 1e-4)  // gamma.y
    }

    func testExportNumKeypoints() throws {
        // C05: num_keypoints counts only v>0
        let labels = makeSimpleLabels(
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),    // v=2
                Point(x: .nan, y: .nan, visible: false, complete: false),  // v=0
                Point(x: 50, y: 60, visible: false, complete: true),   // v=1
            ]
        )

        let path = temporaryPath("export_numkps.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let annotations = parsed["annotations"] as! [[String: Any]]

        // Only 2 keypoints have v > 0 (the visible one v=2 and the occluded one v=1)
        XCTAssertEqual(annotations[0]["num_keypoints"] as? Int, 2)
    }

    func testExportBBox() throws {
        // C05: bbox computed from finite point coordinates
        let labels = makeSimpleLabels(
            points: [
                Point(x: 100, y: 200, visible: true, complete: true),
                Point(x: .nan, y: .nan, visible: false, complete: false),  // NaN should be excluded
                Point(x: 300, y: 400, visible: true, complete: true),
            ]
        )

        let path = temporaryPath("export_bbox.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let annotations = parsed["annotations"] as! [[String: Any]]
        let bbox = annotations[0]["bbox"] as! [NSNumber]

        // bbox = [xmin, ymin, width, height] from finite points only
        XCTAssertEqual(bbox[0].floatValue, 100, accuracy: 1e-4)  // xmin
        XCTAssertEqual(bbox[1].floatValue, 200, accuracy: 1e-4)  // ymin
        XCTAssertEqual(bbox[2].floatValue, 200, accuracy: 1e-4)  // width = 300-100
        XCTAssertEqual(bbox[3].floatValue, 200, accuracy: 1e-4)  // height = 400-200
    }

    func testExportArea() throws {
        // C05: area == bbox.width * bbox.height
        let labels = makeSimpleLabels(
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),
                Point(x: 50, y: 80, visible: true, complete: true),
                Point(x: 30, y: 50, visible: true, complete: true),
            ]
        )

        let path = temporaryPath("export_area.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let annotations = parsed["annotations"] as! [[String: Any]]
        let bbox = annotations[0]["bbox"] as! [NSNumber]
        let area = annotations[0]["area"] as! NSNumber

        let expectedArea = bbox[2].floatValue * bbox[3].floatValue
        XCTAssertEqual(area.floatValue, expectedArea, accuracy: 1e-2)
    }

    func testExportScoreForPredicted() throws {
        // C05: score written for PredictedInstance
        let labels = makeSimpleLabels(
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),
                Point(x: 30, y: 40, visible: true, complete: true),
                Point(x: 50, y: 60, visible: true, complete: true),
            ],
            predicted: true,
            score: 0.95
        )

        let path = temporaryPath("export_score.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let annotations = parsed["annotations"] as! [[String: Any]]

        let score = annotations[0]["score"] as? NSNumber
        XCTAssertNotNil(score)
        XCTAssertEqual(score!.floatValue, 0.95, accuracy: 1e-4)
    }

    func testExportVisibilityRules() throws {
        // C05: visible+finite→v=2, invisible+finite→v=1, NaN→v=0 with 0,0 coords
        let labels = makeSimpleLabels(
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),        // v=2
                Point(x: 30, y: 40, visible: false, complete: true),       // v=1
                Point(x: .nan, y: .nan, visible: false, complete: false),  // v=0
            ]
        )

        let path = temporaryPath("export_vis.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let annotations = parsed["annotations"] as! [[String: Any]]
        let kps = annotations[0]["keypoints"] as! [NSNumber]

        // Point 0: visible+finite → v=2
        XCTAssertEqual(kps[0].floatValue, 10.0, accuracy: 1e-4)
        XCTAssertEqual(kps[1].floatValue, 20.0, accuracy: 1e-4)
        XCTAssertEqual(kps[2].intValue, 2)

        // Point 1: invisible+finite → v=1
        XCTAssertEqual(kps[3].floatValue, 30.0, accuracy: 1e-4)
        XCTAssertEqual(kps[4].floatValue, 40.0, accuracy: 1e-4)
        XCTAssertEqual(kps[5].intValue, 1)

        // Point 2: NaN → v=0, coordinates emitted as 0,0
        XCTAssertEqual(kps[6].floatValue, 0.0, accuracy: 1e-4)
        XCTAssertEqual(kps[7].floatValue, 0.0, accuracy: 1e-4)
        XCTAssertEqual(kps[8].intValue, 0)
    }

    // MARK: - C06: Width/height requirements

    func testExportWithoutDimensionsThrows() throws {
        // C06: video without frameSize → throws videoError
        let labels = makeSimpleLabels(
            frameSize: nil,  // no dimensions
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),
                Point(x: 30, y: 40, visible: true, complete: true),
                Point(x: 50, y: 60, visible: true, complete: true),
            ]
        )

        let path = temporaryPath("export_nodims.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try COCOCodec.write(labels, to: path)) { error in
            guard case SleapIOError.videoError = error else {
                XCTFail("Expected SleapIOError.videoError, got \(error)")
                return
            }
        }
    }

    // MARK: - C07: Losses

    func testTracksDroppedOnExport() throws {
        // C07: instances with tracks → no track info in exported JSON
        let track = Track(name: "animal_0")
        let labels = makeSimpleLabels(
            points: [
                Point(x: 10, y: 20, visible: true, complete: true),
                Point(x: 30, y: 40, visible: true, complete: true),
                Point(x: 50, y: 60, visible: true, complete: true),
            ],
            track: track
        )

        let path = temporaryPath("export_tracks.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let annotations = parsed["annotations"] as! [[String: Any]]

        // No track-related keys in annotation
        XCTAssertNil(annotations[0]["track"])
        XCTAssertNil(annotations[0]["track_id"])
        XCTAssertNil(annotations[0]["tracking_score"])
    }

    // MARK: - Round-trip

    func testRoundTripPreservesInstances() throws {
        // Round-trip: write then read preserves instance count, coordinates, visibility
        let labels = makeSimpleLabels(
            nodeNames: ["head", "body", "tail"],
            edges: [(0, 1), (1, 2)],
            points: [
                Point(x: 100, y: 200, visible: true, complete: true),
                Point(x: 150, y: 250, visible: false, complete: true),
                Point(x: .nan, y: .nan, visible: false, complete: false),
            ]
        )

        let path = temporaryPath("roundtrip.json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try COCOCodec.write(labels, to: path)
        let reloaded = try COCOCodec.read(from: path)

        // Structure
        XCTAssertEqual(reloaded.frameCount, 1)
        XCTAssertEqual(reloaded[0].instances.count, 1)
        XCTAssertEqual(reloaded.skeletons[0].nodes.count, 3)

        let inst = reloaded[0].instances[0]

        // Point 0: was visible+finite → v=2 → imports as visible, finite
        XCTAssertEqual(inst.points[0].x, 100, accuracy: 1e-2)
        XCTAssertEqual(inst.points[0].y, 200, accuracy: 1e-2)
        XCTAssertTrue(inst.points[0].visible)
        XCTAssertTrue(inst.points[0].complete)

        // Point 1: was invisible+finite → v=1 → imports as occluded
        XCTAssertEqual(inst.points[1].x, 150, accuracy: 1e-2)
        XCTAssertEqual(inst.points[1].y, 250, accuracy: 1e-2)
        XCTAssertFalse(inst.points[1].visible)
        XCTAssertTrue(inst.points[1].complete)

        // Point 2: was NaN → v=0 → imports as NaN
        XCTAssertTrue(inst.points[2].x.isNaN)
        XCTAssertTrue(inst.points[2].y.isNaN)
        XCTAssertFalse(inst.points[2].visible)
        XCTAssertFalse(inst.points[2].complete)
    }

    // MARK: - Error handling (P06)

    func testNonexistentFileThrows() throws {
        // P06: nonexistent path → throws fileNotFound
        XCTAssertThrowsError(try COCOCodec.read(from: "/nonexistent/path/to/coco.json")) { error in
            guard case SleapIOError.fileNotFound = error else {
                XCTFail("Expected SleapIOError.fileNotFound, got \(error)")
                return
            }
        }
    }

    func testMalformedJSONThrows() throws {
        // P06: malformed JSON → throws corruptData
        let path = writeTempCOCO("{ this is not valid json !!!")
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try COCOCodec.read(from: path)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    func testMissingCategoryRefThrows() throws {
        // P06: annotation references nonexistent category → throws corruptData
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 999,  // no such category
                    "keypoints": [10.0, 20.0, 2],
                    "bbox": [10, 20, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try COCOCodec.read(from: path)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    // MARK: - Identity (P04)

    func testRepeatedSkeletonRefsShareIdentity() throws {
        // P04: multiple annotations with same category_id share one Skeleton object (===)
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head", "tail"]],
            ],
            images: [
                ["id": 1, "file_name": "a.jpg", "width": 100, "height": 100],
                ["id": 2, "file_name": "b.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2, 30.0, 40.0, 2],
                    "bbox": [10, 20, 20, 20], "area": 400, "iscrowd": 0,
                ],
                [
                    "id": 2, "image_id": 2, "category_id": 1,
                    "keypoints": [50.0, 60.0, 2, 70.0, 80.0, 2],
                    "bbox": [50, 60, 20, 20], "area": 400, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertEqual(labels.skeletons.count, 1)
        let skel0 = labels[0].instances[0].skeleton
        let skel1 = labels[1].instances[0].skeleton
        XCTAssertTrue(skel0 === skel1, "Same category_id must produce shared Skeleton identity")
    }

    func testRepeatedVideoRefsShareIdentity() throws {
        // P04: two annotations referencing same image_id → same frame, same Video
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2],
                    "bbox": [10, 20, 0, 0], "area": 0, "iscrowd": 0,
                ],
                [
                    "id": 2, "image_id": 1, "category_id": 1,
                    "keypoints": [30.0, 40.0, 2],
                    "bbox": [30, 40, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        // Both annotations are for image_id 1 → one frame with 2 instances
        XCTAssertEqual(labels.frameCount, 1)
        XCTAssertEqual(labels[0].instances.count, 2)
        XCTAssertEqual(labels.videos.count, 1)

        // Both instances are in the same frame on the same video
        let video = labels[0].video
        XCTAssertTrue(labels.videos[0] === video)
    }

    // MARK: - Eager load (P02)

    func testImportIsEager() throws {
        // P02: imported Labels.isLazy == false
        let json = cocoJSON(
            categories: [
                ["id": 1, "name": "animal", "keypoints": ["head"]],
            ],
            images: [
                ["id": 1, "file_name": "img.jpg", "width": 100, "height": 100],
            ],
            annotations: [
                [
                    "id": 1, "image_id": 1, "category_id": 1,
                    "keypoints": [10.0, 20.0, 2],
                    "bbox": [10, 20, 0, 0], "area": 0, "iscrowd": 0,
                ],
            ]
        )
        let path = writeTempCOCO(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let labels = try COCOCodec.read(from: path)

        XCTAssertFalse(labels.isLazy, "COCO import should be eager (isLazy == false)")
    }
}

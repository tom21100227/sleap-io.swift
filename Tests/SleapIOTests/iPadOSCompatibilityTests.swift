import XCTest
@testable import SleapIO

/// Validates that the SleapIO module works independently of SleapHDF5/CHDF5.
/// This is the critical test for iPadOS support: all these types and codecs
/// must function without any HDF5 dependency.
final class iPadOSCompatibilityTests: XCTestCase {

    // MARK: - Model Type Construction

    func testAllModelTypesConstructWithoutHDF5() {
        // Node
        let head = Node(name: "head")
        let thorax = Node(name: "thorax")
        let tail = Node(name: "tail")
        XCTAssertEqual(head.name, "head")

        // Edge
        let edge = Edge(source: head, destination: thorax)
        XCTAssertTrue(edge.source === head)

        // Symmetry
        let sym = Symmetry(head, tail)
        XCTAssertTrue(sym.nodeA === head)

        // Skeleton
        let skeleton = Skeleton(name: "fly", nodes: [head, thorax, tail])
        skeleton.addEdge(from: head, to: thorax)
        skeleton.addEdge(from: thorax, to: tail)
        XCTAssertEqual(skeleton.nodes.count, 3)
        XCTAssertEqual(skeleton.edges.count, 2)

        // Track
        let track = Track(name: "animal_1")
        XCTAssertEqual(track.name, "animal_1")

        // Video
        let video = Video(filename: "test.mp4")
        XCTAssertEqual(video.filename, "test.mp4")

        // Point
        let point = Point(x: 10.5, y: 20.3, visible: true, complete: true)
        XCTAssertEqual(point.x, 10.5)

        // PointsArray
        var points = PointsArray(count: 3)
        points[0] = Point(x: 1.0, y: 2.0, visible: true, complete: false)
        points[1] = Point(x: 3.0, y: 4.0, visible: true, complete: false)
        points[2] = Point(x: 5.0, y: 6.0, visible: false, complete: false)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].x, 1.0)

        // Instance
        let instance = Instance(skeleton: skeleton, points: points, track: track)
        XCTAssertTrue(instance.skeleton === skeleton)
        XCTAssertTrue(instance.track === track)
        XCTAssertEqual(instance.points.count, 3)

        // PredictedInstance
        let predPoints = PredictedPointsArray(count: 3)
        let predicted = PredictedInstance(
            skeleton: skeleton, points: predPoints, score: 0.95, track: track
        )
        XCTAssertTrue(predicted is PredictedInstance)
        XCTAssertEqual(predicted.score, 0.95)

        // LabeledFrame
        let frame = LabeledFrame(video: video, frameIndex: 42, instances: [instance, predicted])
        XCTAssertEqual(frame.frameIndex, 42)
        XCTAssertEqual(frame.instances.count, 2)
        XCTAssertEqual(frame.userInstances.count, 1)
        XCTAssertEqual(frame.predictedInstances.count, 1)

        // Labels
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )
        XCTAssertEqual(labels.frameCount, 1)
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertEqual(labels.skeletons.count, 1)
        XCTAssertEqual(labels.tracks.count, 1)

        // SuggestionFrame
        let suggestion = SuggestionFrame(video: video, frameIndex: 10)
        XCTAssertEqual(suggestion.frameIndex, 10)

        // Camera
        let camera = Camera(name: "cam1")
        XCTAssertEqual(camera.name, "cam1")

        // RecordingSession
        let session = RecordingSession()
        XCTAssertNotNil(session)
    }

    // MARK: - Identity Semantics

    func testIdentityEqualityForReferenceTypes() {
        let node1 = Node(name: "head")
        let node2 = Node(name: "head")

        // Same name but different objects — not equal
        XCTAssertFalse(node1 === node2)
        XCTAssertNotEqual(node1, node2)

        // Same object — equal
        let node3 = node1
        XCTAssertTrue(node1 === node3)
        XCTAssertEqual(node1, node3)
    }

    func testSharedIdentityAcrossGraph() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head"), Node(name: "thorax")])
        let video = Video(filename: "v.mp4")
        let track = Track(name: "t1")

        let inst1 = Instance(skeleton: skeleton, track: track)
        let inst2 = Instance(skeleton: skeleton, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst1, inst2])

        // All instances share the same skeleton and track object
        XCTAssertTrue(frame.instances[0].skeleton === frame.instances[1].skeleton)
        XCTAssertTrue(frame.instances[0].track === frame.instances[1].track)
    }

    // MARK: - PointsArray Operations

    func testPointsArraySubscript() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "a"), Node(name: "b")])
        var points = PointsArray(count: 2)
        points[0] = Point(x: 10, y: 20, visible: true, complete: false)
        points[1] = Point(x: 30, y: 40, visible: false, complete: true)

        // Subscript by index
        XCTAssertEqual(points[0].x, 10)
        XCTAssertEqual(points[1].y, 40)
        XCTAssertTrue(points[0].visible)
        XCTAssertFalse(points[1].visible)

        // Subscript by Node
        let instance = Instance(skeleton: skeleton, points: points)
        let ptA = instance[skeleton.nodes[0]]
        XCTAssertEqual(ptA.x, 10)
        XCTAssertEqual(ptA.y, 20)
    }

    func testPointsArrayVisibilityFilter() {
        var points = PointsArray(count: 4)
        points[0] = Point(x: 1, y: 1, visible: true, complete: false)
        points[1] = Point(x: 2, y: 2, visible: false, complete: false)
        points[2] = Point(x: 3, y: 3, visible: true, complete: false)
        points[3] = Point(x: 4, y: 4, visible: false, complete: false)

        let visibleCount = points.visibility.filter { $0 }.count
        XCTAssertEqual(visibleCount, 2)
    }

    // MARK: - DictionaryCodec Round-Trip

    func testDictionaryCodecRoundTripWithoutHDF5() throws {
        let skeleton = Skeleton(name: "mouse", nodes: [
            Node(name: "nose"),
            Node(name: "ear_left"),
            Node(name: "ear_right"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[2])
        skeleton.addSymmetry(skeleton.nodes[1], skeleton.nodes[2])

        let video = Video(filename: "mouse_video.mp4")
        let track = Track(name: "mouse_1")

        var points = PointsArray(count: 3)
        points[0] = Point(x: 100.5, y: 200.3, visible: true, complete: true)
        points[1] = Point(x: 110.0, y: 190.0, visible: true, complete: false)
        points[2] = Point(x: 120.0, y: 195.0, visible: true, complete: false)

        let instance = Instance(skeleton: skeleton, points: points, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 5, instances: [instance])

        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        // Round-trip through dictionary
        let dict = DictionaryCodec.encode(labels)
        let decoded = try DictionaryCodec.decode(dict)

        // Structural integrity
        XCTAssertEqual(decoded.frameCount, 1)
        XCTAssertEqual(decoded.videos.count, 1)
        XCTAssertEqual(decoded.skeletons.count, 1)
        XCTAssertEqual(decoded.tracks.count, 1)

        // Skeleton preserved
        let decodedSkel = decoded.skeletons[0]
        XCTAssertEqual(decodedSkel.name, "mouse")
        XCTAssertEqual(decodedSkel.nodes.count, 3)
        XCTAssertEqual(decodedSkel.edges.count, 2)

        // Point data preserved
        let decodedFrame = decoded[0]
        XCTAssertEqual(decodedFrame.frameIndex, 5)
        let decodedInst = decodedFrame.instances[0]
        XCTAssertEqual(decodedInst.points[0].x, 100.5, accuracy: 1e-4)
        XCTAssertEqual(decodedInst.points[0].y, 200.3, accuracy: 1e-4)
    }

    // MARK: - COCOCodec Write + Read Round-Trip

    func testCOCOCodecRoundTripWithoutHDF5() throws {
        let skeleton = Skeleton(name: "ant", nodes: [
            Node(name: "head"),
            Node(name: "body"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])

        let video = Video(filename: "ant.png")
        video.frameCount = 1
        video.frameSize = (height: 480, width: 640, channels: 3)

        var points = PointsArray(count: 2)
        points[0] = Point(x: 100, y: 200, visible: true, complete: false)
        points[1] = Point(x: 150, y: 250, visible: true, complete: false)

        let instance = Instance(skeleton: skeleton, points: points)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [instance])

        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        // Write to temp file and read back
        let tmpPath = NSTemporaryDirectory() + "ipad_test_coco_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        try COCOCodec.write(labels, to: tmpPath)
        let decoded = try COCOCodec.read(from: tmpPath)

        XCTAssertEqual(decoded.frameCount, 1)
        XCTAssertEqual(decoded[0].instances.count, 1)
        XCTAssertEqual(decoded[0].instances[0].points.count, 2)
    }

    // MARK: - CSVCodec Write + Read Round-Trip

    func testCSVCodecRoundTripWithoutHDF5() throws {
        let skeleton = Skeleton(name: "bee", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
            Node(name: "abdomen"),
        ])

        let video = Video(filename: "bee.mp4")
        let track = Track(name: "bee_1")

        var points = PointsArray(count: 3)
        points[0] = Point(x: 50, y: 60, visible: true, complete: false)
        points[1] = Point(x: 70, y: 80, visible: true, complete: false)
        points[2] = Point(x: 90, y: 100, visible: false, complete: false)

        let instance = Instance(skeleton: skeleton, points: points, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 10, instances: [instance])

        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        let tmpPath = NSTemporaryDirectory() + "ipad_test_csv_\(UUID().uuidString).csv"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        try CSVCodec.write(labels, to: tmpPath)
        let decoded = try CSVCodec.read(from: tmpPath)

        XCTAssertEqual(decoded.frameCount, 1)
        XCTAssertEqual(decoded[0].frameIndex, 10)
    }

    // MARK: - Transforms

    func testAffineTransformWithoutHDF5() {
        var points = PointsArray(count: 2)
        points[0] = Point(x: 10, y: 20, visible: true, complete: false)
        points[1] = Point(x: 30, y: 40, visible: true, complete: false)

        // Translation matrix: [1, 0, 5, 0, 1, 10, 0, 0, 1]
        points.apply(transform: [1, 0, 5, 0, 1, 10, 0, 0, 1])
        XCTAssertEqual(points[0].x, 15, accuracy: 1e-4)
        XCTAssertEqual(points[0].y, 30, accuracy: 1e-4)
        XCTAssertEqual(points[1].x, 35, accuracy: 1e-4)
        XCTAssertEqual(points[1].y, 50, accuracy: 1e-4)
    }

    // MARK: - Eager Frame Store Operations

    func testEagerFrameStoreOperations() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "n")])
        let video = Video(filename: "v.mp4")

        let frames = (0..<5).map { i in
            LabeledFrame(video: video, frameIndex: i, instances: [
                Instance(skeleton: skeleton),
            ])
        }

        let store = EagerFrameStore(frames: frames)
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        // RandomAccessCollection conformance
        XCTAssertEqual(labels.frameCount, 5)
        XCTAssertEqual(labels[0].frameIndex, 0)
        XCTAssertEqual(labels[4].frameIndex, 4)

        // Not lazy
        XCTAssertFalse(labels.isLazy)
    }

    // MARK: - Labels Computed Properties

    func testLabelsComputedProperties() {
        let skeleton = Skeleton(name: "s", nodes: [Node(name: "n")])
        let video = Video(filename: "v.mp4")
        let track = Track(name: "t")

        let userInst = Instance(skeleton: skeleton, track: track)
        let predInst = PredictedInstance(
            skeleton: skeleton,
            points: PredictedPointsArray(count: 1),
            score: 0.8,
            track: track
        )

        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [userInst, predInst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        XCTAssertEqual(labels.instanceCount, 2)
        XCTAssertEqual(labels.predictedInstanceCount, 1)
        XCTAssertTrue(labels.skeleton === skeleton)
    }
}

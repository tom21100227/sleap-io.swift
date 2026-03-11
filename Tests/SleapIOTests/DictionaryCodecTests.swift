import XCTest
@testable import SleapIO

/// D01-D02: Dictionary codec tests.
final class DictionaryCodecTests: XCTestCase {

    // MARK: - D01: Dictionary codec identity preservation

    func testD01_sharedSkeletonIdentityPreservedAfterRoundTrip() throws {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
            Node(name: "abdomen"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addEdge(from: skeleton.nodes[1], to: skeleton.nodes[2])

        let track = Track(name: "track1")
        let video = Video(filename: "test.mp4")

        let inst1 = Instance(skeleton: skeleton, track: track)
        let inst2 = Instance(skeleton: skeleton, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [inst1, inst2])

        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        // Encode to dictionary and decode back
        let dict = DictionaryCodec.encode(labels)
        let decoded = try DictionaryCodec.decode(dict)

        // Verify shared skeleton identity after decode
        XCTAssertEqual(decoded.skeletons.count, 1)
        let decodedSkeleton = decoded.skeletons[0]

        let decodedFrame = decoded[0]
        for inst in decodedFrame.instances {
            XCTAssertTrue(
                inst.skeleton === decodedSkeleton,
                "All instances must share the same decoded Skeleton object"
            )
        }
    }

    func testD01_sharedVideoIdentityPreservedAfterRoundTrip() throws {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "shared_video.mp4")

        let frame0 = LabeledFrame(video: video, frameIndex: 0, instances: [
            Instance(skeleton: skeleton),
        ])
        let frame1 = LabeledFrame(video: video, frameIndex: 1, instances: [
            Instance(skeleton: skeleton),
        ])

        let store = EagerFrameStore(frames: [frame0, frame1])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let dict = DictionaryCodec.encode(labels)
        let decoded = try DictionaryCodec.decode(dict)

        XCTAssertEqual(decoded.videos.count, 1)
        XCTAssertTrue(
            decoded[0].video === decoded[1].video,
            "Frames referencing the same video must share the same Video object after decode"
        )
    }

    func testD01_sharedTrackIdentityPreservedAfterRoundTrip() throws {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let track = Track(name: "animal_0")

        let frame0 = LabeledFrame(video: video, frameIndex: 0, instances: [
            Instance(skeleton: skeleton, track: track),
        ])
        let frame1 = LabeledFrame(video: video, frameIndex: 1, instances: [
            Instance(skeleton: skeleton, track: track),
        ])

        let store = EagerFrameStore(frames: [frame0, frame1])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        let dict = DictionaryCodec.encode(labels)
        let decoded = try DictionaryCodec.decode(dict)

        XCTAssertEqual(decoded.tracks.count, 1)
        let t0 = decoded[0].instances[0].track
        let t1 = decoded[1].instances[0].track
        XCTAssertNotNil(t0)
        XCTAssertNotNil(t1)
        XCTAssertTrue(t0 === t1, "Track identity must be preserved after round-trip")
    }

    func testD01_nodeIdentityPreservedWithinSkeleton() throws {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        skeleton.addSymmetry(skeleton.nodes[0], skeleton.nodes[1])

        let dict = DictionaryCodec.encodeSkeleton(skeleton)
        let decoded = try DictionaryCodec.decodeSkeleton(dict)

        // Nodes referenced in edges should be the same objects as in the node list
        XCTAssertEqual(decoded.edges.count, 1)
        XCTAssertTrue(decoded.edges[0].source === decoded.nodes[0])
        XCTAssertTrue(decoded.edges[0].destination === decoded.nodes[1])

        // Symmetry nodes should also reference the same objects
        XCTAssertEqual(decoded.symmetries.count, 1)
        XCTAssertTrue(decoded.symmetries[0].nodeA === decoded.nodes[0])
        XCTAssertTrue(decoded.symmetries[0].nodeB === decoded.nodes[1])
    }

    // MARK: - D02: Skeleton codec compatibility

    func testD02_skeletonRoundTrip() throws {
        let head = Node(name: "head")
        let thorax = Node(name: "thorax")
        let abdomen = Node(name: "abdomen")
        let leftWing = Node(name: "left_wing")
        let rightWing = Node(name: "right_wing")

        let skeleton = Skeleton(
            name: "Drosophila",
            nodes: [head, thorax, abdomen, leftWing, rightWing],
            edges: [
                Edge(source: head, destination: thorax),
                Edge(source: thorax, destination: abdomen),
                Edge(source: thorax, destination: leftWing),
                Edge(source: thorax, destination: rightWing),
            ],
            symmetries: [
                Symmetry(leftWing, rightWing),
            ]
        )

        let dict = DictionaryCodec.encodeSkeleton(skeleton)
        let decoded = try DictionaryCodec.decodeSkeleton(dict)

        // Verify structure
        XCTAssertEqual(decoded.name, "Drosophila")
        XCTAssertEqual(decoded.nodes.count, 5)
        XCTAssertEqual(decoded.edges.count, 4)
        XCTAssertEqual(decoded.symmetries.count, 1)

        // Verify node names match
        XCTAssertEqual(decoded.nodes.map(\.name), ["head", "thorax", "abdomen", "left_wing", "right_wing"])

        // Verify edge connectivity by name
        XCTAssertEqual(decoded.edges[0].source.name, "head")
        XCTAssertEqual(decoded.edges[0].destination.name, "thorax")

        // Verify symmetry
        let symNames = Set([decoded.symmetries[0].nodeA.name, decoded.symmetries[0].nodeB.name])
        XCTAssertEqual(symNames, Set(["left_wing", "right_wing"]))
    }

    func testD02_skeletonWithNoEdgesOrSymmetries() throws {
        let skeleton = Skeleton(name: "simple", nodes: [
            Node(name: "point1"),
            Node(name: "point2"),
        ])

        let dict = DictionaryCodec.encodeSkeleton(skeleton)
        let decoded = try DictionaryCodec.decodeSkeleton(dict)

        XCTAssertEqual(decoded.name, "simple")
        XCTAssertEqual(decoded.nodes.count, 2)
        XCTAssertTrue(decoded.edges.isEmpty)
        XCTAssertTrue(decoded.symmetries.isEmpty)
    }

    func testD02_fullLabelsRoundTrip() throws {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])
        skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])

        let video = Video(filename: "test.mp4")
        let track = Track(name: "animal_0")

        let points = PointsArray(points: [
            Point(x: 100, y: 200, visible: true),
            Point(x: 150, y: 250, visible: true),
        ])
        let inst = Instance(skeleton: skeleton, points: points, track: track)
        let frame = LabeledFrame(video: video, frameIndex: 42, instances: [inst])

        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )

        let dict = DictionaryCodec.encode(labels)
        let decoded = try DictionaryCodec.decode(dict)

        // Structure checks
        XCTAssertEqual(decoded.frameCount, 1)
        XCTAssertEqual(decoded.videos.count, 1)
        XCTAssertEqual(decoded.skeletons.count, 1)
        XCTAssertEqual(decoded.tracks.count, 1)

        // Data fidelity
        let decodedFrame = decoded[0]
        XCTAssertEqual(decodedFrame.frameIndex, 42)
        XCTAssertEqual(decodedFrame.instances.count, 1)

        let decodedInst = decodedFrame.instances[0]
        XCTAssertEqual(decodedInst.points[0].x, 100, accuracy: 1e-4)
        XCTAssertEqual(decodedInst.points[0].y, 200, accuracy: 1e-4)
        XCTAssertEqual(decodedInst.points[1].x, 150, accuracy: 1e-4)
        XCTAssertEqual(decodedInst.points[1].y, 250, accuracy: 1e-4)
    }
}

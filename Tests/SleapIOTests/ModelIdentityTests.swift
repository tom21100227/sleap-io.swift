import XCTest
@testable import SleapIO

/// M01-M05: Model identity and value semantics tests.
final class ModelIdentityTests: XCTestCase {

    // MARK: - M01: Node identity equality

    func testM01_sameNodeReferenceIsEqual() {
        let node = Node(name: "head")
        let ref = node
        XCTAssertTrue(node == ref, "Same node reference should be equal")
        XCTAssertTrue(node === ref, "Same node reference should be identity-equal")
    }

    func testM01_distinctNodesWithSameNameAreNotEqual() {
        let a = Node(name: "head")
        let b = Node(name: "head")
        XCTAssertFalse(a == b, "Distinct nodes with same name should not be equal")
        XCTAssertFalse(a === b, "Distinct nodes should not be identity-equal")
    }

    func testM01_nodeHashingFollowsIdentity() {
        let a = Node(name: "head")
        let b = Node(name: "head")
        let ref = a

        // Same identity => same hash
        XCTAssertEqual(a.hashValue, ref.hashValue)
        // Different identity => (very likely) different hash
        // We can at least confirm they work in a Set
        let set: Set<Node> = [a, b]
        XCTAssertEqual(set.count, 2, "Two distinct nodes should both be in the set")

        let set2: Set<Node> = [a, ref]
        XCTAssertEqual(set2.count, 1, "Same node added twice should only appear once")
    }

    func testM01_allIdentityTypesUseReferenceEquality() {
        // Track
        let trackA = Track(name: "track1")
        let trackB = Track(name: "track1")
        XCTAssertTrue(trackA == trackA)
        XCTAssertFalse(trackA == trackB)

        // Video
        let videoA = Video(filename: "video.mp4")
        let videoB = Video(filename: "video.mp4")
        XCTAssertTrue(videoA == videoA)
        XCTAssertFalse(videoA == videoB)

        // Camera
        let camA = Camera(name: "cam1")
        let camB = Camera(name: "cam1")
        XCTAssertTrue(camA == camA)
        XCTAssertFalse(camA == camB)

        // Skeleton
        let skelA = Skeleton(name: "skel")
        let skelB = Skeleton(name: "skel")
        XCTAssertTrue(skelA == skelA)
        XCTAssertFalse(skelA == skelB)
    }

    // MARK: - M02: Skeleton shared identity

    func testM02_instancesShareSameSkeleton() {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
            Node(name: "abdomen"),
        ])

        let inst1 = Instance(skeleton: skeleton)
        let inst2 = Instance(skeleton: skeleton)

        XCTAssertTrue(
            inst1.skeleton === inst2.skeleton,
            "Both instances must reference the exact same Skeleton object"
        )
    }

    func testM02_skeletonNodesAreShared() {
        let headNode = Node(name: "head")
        let thoraxNode = Node(name: "thorax")
        let skeleton = Skeleton(name: "fly", nodes: [headNode, thoraxNode])

        // The skeleton's nodes should be the same objects we passed in
        XCTAssertTrue(skeleton.nodes[0] === headNode)
        XCTAssertTrue(skeleton.nodes[1] === thoraxNode)

        // Node lookup should return the same objects
        XCTAssertTrue(skeleton.node(named: "head") === headNode)
        XCTAssertTrue(skeleton.node(named: "thorax") === thoraxNode)
    }

    // MARK: - M03: LabeledFrame identity equality

    func testM03_labeledFrameUsesIdentityEquality() {
        let video = Video(filename: "test.mp4")
        let frameA = LabeledFrame(video: video, frameIndex: 0)
        let frameB = LabeledFrame(video: video, frameIndex: 0)

        XCTAssertTrue(frameA == frameA, "Same LabeledFrame reference should be equal")
        XCTAssertFalse(
            frameA == frameB,
            "Distinct LabeledFrames with same data should not be equal"
        )
    }

    func testM03_instanceUsesIdentityEquality() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let instA = Instance(skeleton: skeleton)
        let instB = Instance(skeleton: skeleton)

        XCTAssertTrue(instA == instA)
        XCTAssertFalse(instA == instB)
    }

    // MARK: - M04: PointsArray ownership (value semantics)

    func testM04_pointsArrayHasValueSemantics() {
        let points = [
            Point(x: 10.0, y: 20.0, visible: true),
            Point(x: 30.0, y: 40.0, visible: true),
        ]
        var arrayA = PointsArray(points: points)
        var arrayB = arrayA  // Copy (value type)

        // Mutate A
        arrayA[0] = Point(x: 999.0, y: 999.0)

        // B should be unaffected
        XCTAssertEqual(arrayB[0].x, 10.0, "Mutation of copy A must not affect copy B")
        XCTAssertEqual(arrayB[0].y, 20.0)

        // Mutate B
        arrayB[1] = Point(x: 0.0, y: 0.0)

        // A should be unaffected
        XCTAssertEqual(arrayA[1].x, 30.0, "Mutation of copy B must not affect copy A")
        XCTAssertEqual(arrayA[1].y, 40.0)
    }

    func testM04_instancePointsMutationIsIndependent() {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])

        let points1 = PointsArray(points: [
            Point(x: 10, y: 20, visible: true),
            Point(x: 30, y: 40, visible: true),
        ])
        let points2 = PointsArray(points: [
            Point(x: 10, y: 20, visible: true),
            Point(x: 30, y: 40, visible: true),
        ])

        let inst1 = Instance(skeleton: skeleton, points: points1)
        let inst2 = Instance(skeleton: skeleton, points: points2)

        // Mutate inst1's points
        inst1.points[0] = Point(x: 999, y: 999)

        // inst2's points should be unaffected
        XCTAssertEqual(inst2.points[0].x, 10.0)
        XCTAssertEqual(inst2.points[0].y, 20.0)
    }

    func testM04_coordinateBufferOwnership() {
        // Create a PointsArray from raw coordinates and verify copy semantics
        var coords = ContiguousArray<Float>([1, 2, 3, 4])
        let vis = ContiguousArray<Bool>([true, true])
        let comp = ContiguousArray<Bool>([false, false])

        var array = PointsArray(coordinates: coords, visibility: vis, completeness: comp)

        // Mutate the original ContiguousArray — should NOT affect the PointsArray
        // (ContiguousArray has copy-on-write, so assigning to `array` made a logical copy)
        coords[0] = 999
        XCTAssertEqual(array.coordinates[0], 1.0)

        // Mutate the array itself
        array.coordinates[0] = 500
        XCTAssertEqual(coords[0], 999)  // original is unaffected
    }

    // MARK: - M05: PredictedInstance shape

    func testM05_predictedInstanceExposeScoreAndPredictedPoints() {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])

        let predPoints = PredictedPointsArray(points: [
            PredictedPoint(x: 10, y: 20, visible: true, score: 0.95),
            PredictedPoint(x: 30, y: 40, visible: true, score: 0.87),
        ])

        let predInst = PredictedInstance(
            skeleton: skeleton,
            points: predPoints,
            score: 0.91
        )

        // 1. Has base Instance semantics — is an Instance
        XCTAssertTrue(predInst is Instance)

        // 2. Exposes per-instance score
        XCTAssertEqual(predInst.score, 0.91, accuracy: 1e-6)

        // 3. Exposes PredictedPointsArray with per-point scores
        XCTAssertEqual(predInst.predictedPoints.count, 2)
        XCTAssertEqual(predInst.predictedPoints[0].score, 0.95, accuracy: 1e-6)
        XCTAssertEqual(predInst.predictedPoints[1].score, 0.87, accuracy: 1e-6)

        // Points should be accessible via the base Instance `points` property too
        XCTAssertEqual(predInst.points.count, 2)
        XCTAssertEqual(predInst.points[0].x, 10.0, accuracy: 1e-6)
    }

    func testM05_predictedInstanceInLabeledFrame() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")

        let predPoints = PredictedPointsArray(points: [
            PredictedPoint(x: 10, y: 20, visible: true, score: 0.9),
        ])
        let predInst = PredictedInstance(skeleton: skeleton, points: predPoints, score: 0.85)
        let userInst = Instance(skeleton: skeleton)

        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [userInst, predInst])

        XCTAssertEqual(frame.userInstances.count, 1)
        XCTAssertEqual(frame.predictedInstances.count, 1)
        XCTAssertTrue(frame.predictedInstances[0] === predInst)
    }

    // MARK: - Value type semantics for Edge, Symmetry, Point

    func testEdgeValueEquality() {
        let nodeA = Node(name: "a")
        let nodeB = Node(name: "b")
        let edge1 = Edge(source: nodeA, destination: nodeB)
        let edge2 = Edge(source: nodeA, destination: nodeB)
        XCTAssertEqual(edge1, edge2, "Edges with same nodes should be equal")

        let nodeC = Node(name: "c")
        let edge3 = Edge(source: nodeA, destination: nodeC)
        XCTAssertNotEqual(edge1, edge3)
    }

    func testSymmetryIsOrderIndependent() {
        let nodeA = Node(name: "left_eye")
        let nodeB = Node(name: "right_eye")
        let sym1 = Symmetry(nodeA, nodeB)
        let sym2 = Symmetry(nodeB, nodeA)
        XCTAssertEqual(sym1, sym2, "Symmetry should be order-independent")
    }

    func testPointValueSemantics() {
        var p1 = Point(x: 10, y: 20, visible: true)
        let p2 = p1
        p1.x = 999
        XCTAssertEqual(p2.x, 10, "Point should have value semantics")
    }

    func testPredictedPointValueSemantics() {
        var pp1 = PredictedPoint(x: 10, y: 20, score: 0.5)
        let pp2 = pp1
        pp1.x = 999
        XCTAssertEqual(pp2.x, 10, "PredictedPoint should have value semantics")
    }

    // MARK: - Skeleton collection conformance

    func testSkeletonRandomAccessCollection() {
        let nodes = [Node(name: "a"), Node(name: "b"), Node(name: "c")]
        let skeleton = Skeleton(name: "test", nodes: nodes)

        XCTAssertEqual(skeleton.count, 3)
        XCTAssertTrue(skeleton[0] === nodes[0])
        XCTAssertTrue(skeleton[1] === nodes[1])
        XCTAssertTrue(skeleton[2] === nodes[2])

        // Index lookup
        XCTAssertEqual(skeleton.index(of: nodes[1]), 1)
    }

    func testSkeletonNodeLookupByName() {
        let head = Node(name: "head")
        let thorax = Node(name: "thorax")
        let skeleton = Skeleton(name: "fly", nodes: [head, thorax])

        XCTAssertTrue(skeleton.node(named: "head") === head)
        XCTAssertTrue(skeleton.node(named: "thorax") === thorax)
        XCTAssertNil(skeleton.node(named: "nonexistent"))
    }

    // MARK: - LabeledFrame.addInstance convenience

    func testAddInstance_returnedInstanceHasCorrectSkeleton() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0)

        let instance = frame.addInstance(skeleton: skeleton)

        XCTAssertTrue(instance.skeleton === skeleton)
    }

    func testAddInstance_returnedInstanceHasCorrectTrack() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0)
        let track = Track(name: "animal_0")

        let instance = frame.addInstance(skeleton: skeleton, track: track)

        XCTAssertTrue(instance.track === track)
    }

    func testAddInstance_returnedInstanceHasNilTrackWhenOmitted() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0)

        let instance = frame.addInstance(skeleton: skeleton)

        XCTAssertNil(instance.track)
    }

    func testAddInstance_instanceIsAppendedToFrameList() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0)
        XCTAssertEqual(frame.instances.count, 0)

        let instance = frame.addInstance(skeleton: skeleton)

        XCTAssertEqual(frame.instances.count, 1)
        XCTAssertTrue(frame.instances[0] === instance)
    }

    func testAddInstance_returnedInstanceIsIdentityStableWithLast() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0)

        let instance = frame.addInstance(skeleton: skeleton)

        XCTAssertTrue(instance === frame.instances.last)
    }

    func testAddInstance_multipleCallsAppendMultipleInstances() {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head")])
        let video = Video(filename: "test.mp4")
        let frame = LabeledFrame(video: video, frameIndex: 0)

        let inst1 = frame.addInstance(skeleton: skeleton)
        let inst2 = frame.addInstance(skeleton: skeleton, track: Track(name: "t1"))
        let inst3 = frame.addInstance(skeleton: skeleton)

        XCTAssertEqual(frame.instances.count, 3)
        XCTAssertTrue(frame.instances[0] === inst1)
        XCTAssertTrue(frame.instances[1] === inst2)
        XCTAssertTrue(frame.instances[2] === inst3)
        XCTAssertFalse(inst1 === inst2)
        XCTAssertFalse(inst2 === inst3)
    }
}

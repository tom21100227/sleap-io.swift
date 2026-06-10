import XCTest
@testable import SleapIO

/// E1.3: `Labels.copy()` deep snapshot tests.
///
/// Verifies that `copy()` produces a deep, identity-preserving clone:
/// distinct objects, independent mutation, identity dedup across the cloned
/// graph, and preserved counts.
final class LabelsCopyTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a multi-video, multi-track Labels with both user and predicted
    /// instances, edges, symmetries, suggestions, provenance, rois, and masks.
    private func makeTestLabels() -> Labels {
        let videoA = Video(filename: "videoA.mp4")
        videoA.frameCount = 100
        videoA.frameSize = (height: 480, width: 640, channels: 3)
        videoA.persistedFilename = "videoA_moved.mp4"

        let videoB = Video(filename: "videoB.mp4",
                           backendType: "hdf5",
                           backendMetadata: ["dataset": "video0/video"])
        videoB.frameCount = 50

        // videoB is derived from videoA.
        videoB.sourceVideo = videoA

        let head = Node(name: "head")
        let thorax = Node(name: "thorax")
        let abdomen = Node(name: "abdomen")
        let skeleton = Skeleton(name: "fly", nodes: [head, thorax, abdomen])
        skeleton.addEdge(from: head, to: thorax)
        skeleton.addEdge(from: thorax, to: abdomen)
        skeleton.addSymmetry(head, abdomen)

        let trackX = Track(name: "track_x")
        let trackY = Track(name: "track_y")

        // A user instance with concrete point values.
        let userInst = Instance(skeleton: skeleton, track: trackX, trackingScore: 0.9)
        userInst[head] = Point(x: 1, y: 2, visible: true, complete: true)
        userInst[thorax] = Point(x: 3, y: 4, visible: true, complete: false)
        userInst[abdomen] = Point(x: 5, y: 6, visible: false, complete: false)

        // A predicted instance with scores.
        var ppa = PredictedPointsArray(count: 3)
        ppa.skeleton = skeleton
        ppa[0] = PredictedPoint(x: 10, y: 11, visible: true, complete: true, score: 0.5)
        ppa[1] = PredictedPoint(x: 12, y: 13, visible: true, complete: false, score: 0.6)
        ppa[2] = PredictedPoint(x: 14, y: 15, visible: false, complete: false, score: 0.7)
        let predInst = PredictedInstance(skeleton: skeleton,
                                         points: ppa,
                                         score: 0.85,
                                         track: trackY,
                                         trackingScore: 0.8)

        let frameA0 = LabeledFrame(video: videoA, frameIndex: 0, instances: [userInst, predInst])
        let frameA1 = LabeledFrame(video: videoA, frameIndex: 1, instances: [
            Instance(skeleton: skeleton, track: trackX),
        ])
        let frameB0 = LabeledFrame(video: videoB, frameIndex: 0, instances: [
            Instance(skeleton: skeleton, track: trackY),
        ], isNegative: false)

        let store = EagerFrameStore(frames: [frameA0, frameA1, frameB0])

        let suggestion = SuggestionFrame(video: videoB, frameIndex: 7, group: "g1")
        let roi = ROI(annotationType: .boundingBox, name: "roi1",
                      points: [SIMD2(0, 0), SIMD2(10, 10)])
        let mask = SegmentationMask(rleCounts: [2, 3, 4], height: 3, width: 3, name: "mask1")

        return Labels(
            frameStore: store,
            videos: [videoA, videoB],
            skeletons: [skeleton],
            tracks: [trackX, trackY],
            suggestions: [suggestion],
            sessions: [],
            provenance: ["sleap_version": "1.5.0", "source": "test"],
            rois: [roi],
            masks: [mask]
        )
    }

    // MARK: - Distinct top-level object

    func testCopyIsDistinctObject() {
        let original = makeTestLabels()
        let clone = original.copy()
        XCTAssertFalse(clone === original, "copy() must return a new Labels object")
    }

    // MARK: - Identity-table objects are cloned (not shared)

    func testIdentityTablesAreCloned() {
        let original = makeTestLabels()
        let clone = original.copy()

        XCTAssertEqual(clone.videos.count, original.videos.count)
        XCTAssertEqual(clone.skeletons.count, original.skeletons.count)
        XCTAssertEqual(clone.tracks.count, original.tracks.count)

        for (o, c) in zip(original.videos, clone.videos) {
            XCTAssertFalse(o === c, "Each cloned video must be a new object")
        }
        for (o, c) in zip(original.skeletons, clone.skeletons) {
            XCTAssertFalse(o === c, "Each cloned skeleton must be a new object")
        }
        for (o, c) in zip(original.tracks, clone.tracks) {
            XCTAssertFalse(o === c, "Each cloned track must be a new object")
        }
    }

    func testClonedSkeletonHasNewNodesAndRemappedTopology() {
        let original = makeTestLabels()
        let clone = original.copy()

        let oSkel = original.skeletons[0]
        let cSkel = clone.skeletons[0]

        XCTAssertEqual(cSkel.name, oSkel.name)
        XCTAssertEqual(cSkel.nodes.map(\.name), oSkel.nodes.map(\.name))

        // Nodes are new objects.
        for (o, c) in zip(oSkel.nodes, cSkel.nodes) {
            XCTAssertFalse(o === c, "Cloned skeleton must have new Node objects")
        }

        // Edges remapped to the cloned skeleton's own nodes.
        XCTAssertEqual(cSkel.edges.count, oSkel.edges.count)
        let cNodeSet = Set(cSkel.nodes.map { ObjectIdentifier($0) })
        for edge in cSkel.edges {
            XCTAssertTrue(cNodeSet.contains(ObjectIdentifier(edge.source)),
                          "Edge source must reference a cloned node")
            XCTAssertTrue(cNodeSet.contains(ObjectIdentifier(edge.destination)),
                          "Edge destination must reference a cloned node")
        }

        // Symmetries remapped too.
        XCTAssertEqual(cSkel.symmetries.count, oSkel.symmetries.count)
        for sym in cSkel.symmetries {
            XCTAssertTrue(cNodeSet.contains(ObjectIdentifier(sym.nodeA)))
            XCTAssertTrue(cNodeSet.contains(ObjectIdentifier(sym.nodeB)))
        }
    }

    func testClonedVideoScalarPropertiesCopied() {
        let original = makeTestLabels()
        let clone = original.copy()

        let oVidA = original.videos[0]
        let cVidA = clone.videos[0]
        XCTAssertEqual(cVidA.originalFilename, oVidA.originalFilename)
        XCTAssertEqual(cVidA.persistedFilename, oVidA.persistedFilename)
        XCTAssertEqual(cVidA.filename, oVidA.filename)
        XCTAssertEqual(cVidA.frameCount, oVidA.frameCount)
        XCTAssertEqual(cVidA.frameSize?.height, oVidA.frameSize?.height)
        XCTAssertEqual(cVidA.frameSize?.width, oVidA.frameSize?.width)
        XCTAssertEqual(cVidA.frameSize?.channels, oVidA.frameSize?.channels)

        let oVidB = original.videos[1]
        let cVidB = clone.videos[1]
        XCTAssertEqual(cVidB.backendType, oVidB.backendType)
        XCTAssertEqual(cVidB.frameCount, oVidB.frameCount)

        // sourceVideo should be remapped to the cloned source video (videoA).
        XCTAssertNotNil(cVidB.sourceVideo)
        XCTAssertTrue(cVidB.sourceVideo === cVidA,
                      "sourceVideo must point to the cloned source video, not the original")
    }

    // MARK: - Identity dedup across the cloned graph

    func testFrameVideoIdentityDedup() {
        let original = makeTestLabels()
        let clone = original.copy()

        for frame in clone {
            let matchIndex = clone.videos.firstIndex { $0 === frame.video }
            XCTAssertNotNil(matchIndex,
                            "Each cloned frame.video must be one of the cloned Labels' videos")
        }

        // frameA0 -> videos[0], frameB0 -> videos[1]
        XCTAssertTrue(clone[0].video === clone.videos[0])
        XCTAssertTrue(clone[2].video === clone.videos[1])
    }

    func testInstanceSkeletonAndTrackIdentityDedup() {
        let original = makeTestLabels()
        let clone = original.copy()

        for frame in clone {
            for inst in frame.instances {
                let skelMatch = clone.skeletons.firstIndex { $0 === inst.skeleton }
                XCTAssertNotNil(skelMatch,
                                "Each cloned instance.skeleton must be one of the cloned skeletons")
                if let track = inst.track {
                    let trackMatch = clone.tracks.firstIndex { $0 === track }
                    XCTAssertNotNil(trackMatch,
                                    "Each cloned instance.track must be one of the cloned tracks")
                }
            }
        }

        // Specifically: instance.skeleton === clone.skeletons[0]
        XCTAssertTrue(clone[0].instances[0].skeleton === clone.skeletons[0])
        // First user instance track is trackX === clone.tracks[0]
        XCTAssertTrue(clone[0].instances[0].track === clone.tracks[0])
        // Predicted instance track is trackY === clone.tracks[1]
        XCTAssertTrue(clone[0].instances[1].track === clone.tracks[1])
    }

    // MARK: - Counts preserved

    func testCountsMatchOriginal() {
        let original = makeTestLabels()
        let clone = original.copy()

        XCTAssertEqual(clone.frameCount, original.frameCount)
        XCTAssertEqual(clone.instanceCount, original.instanceCount)
        XCTAssertEqual(clone.predictedInstanceCount, original.predictedInstanceCount)

        // Per-frame instance counts match.
        for i in 0..<original.frameCount {
            XCTAssertEqual(clone[i].instances.count, original[i].instances.count)
            XCTAssertEqual(clone[i].frameIndex, original[i].frameIndex)
        }
    }

    func testMetadataCopied() {
        let original = makeTestLabels()
        let clone = original.copy()

        XCTAssertEqual(clone.provenance, original.provenance)
        XCTAssertEqual(clone.suggestions.count, original.suggestions.count)
        XCTAssertEqual(clone.rois.count, original.rois.count)
        XCTAssertEqual(clone.masks.count, original.masks.count)

        // Suggestion video remapped to cloned video.
        if let s = clone.suggestions.first {
            XCTAssertEqual(s.frameIndex, 7)
            XCTAssertEqual(s.group, "g1")
            XCTAssertTrue(clone.videos.contains { $0 === s.video },
                          "Suggestion video must be remapped to a cloned video")
        }
    }

    // MARK: - Point/instance values cloned

    func testPointValuesCopied() {
        let original = makeTestLabels()
        let clone = original.copy()

        let oInst = original[0].instances[0]
        let cInst = clone[0].instances[0]
        XCTAssertEqual(cInst.points.count, oInst.points.count)
        for i in 0..<oInst.points.count {
            XCTAssertEqual(cInst.points[i].x, oInst.points[i].x)
            XCTAssertEqual(cInst.points[i].y, oInst.points[i].y)
            XCTAssertEqual(cInst.points[i].visible, oInst.points[i].visible)
            XCTAssertEqual(cInst.points[i].complete, oInst.points[i].complete)
        }
        XCTAssertEqual(cInst.trackingScore, oInst.trackingScore)

        // Predicted instance scores/values.
        guard let oPred = original[0].instances[1] as? PredictedInstance,
              let cPred = clone[0].instances[1] as? PredictedInstance else {
            return XCTFail("Expected a predicted instance at frame 0, index 1")
        }
        XCTAssertEqual(cPred.score, oPred.score)
        XCTAssertEqual(cPred.predictedPoints.scores, oPred.predictedPoints.scores)
        for i in 0..<oPred.predictedPoints.count {
            XCTAssertEqual(cPred.predictedPoints[i].score, oPred.predictedPoints[i].score)
            XCTAssertEqual(cPred.predictedPoints[i].x, oPred.predictedPoints[i].x)
        }
    }

    // MARK: - Independence: mutating the copy must not affect the original

    func testMutatingCopiedPointDoesNotAffectOriginal() {
        let original = makeTestLabels()
        let clone = original.copy()

        let originalX = original[0].instances[0].points[0].x

        // Mutate a point in the clone.
        clone[0].instances[0].points[0] = Point(x: 999, y: 888, visible: false, complete: false)

        XCTAssertEqual(clone[0].instances[0].points[0].x, 999)
        XCTAssertEqual(original[0].instances[0].points[0].x, originalX,
                       "Mutating a cloned point must not affect the original")
        XCTAssertNotEqual(original[0].instances[0].points[0].x, 999)
    }

    func testMutatingClonedInstanceTrackDoesNotAffectOriginal() {
        let original = makeTestLabels()
        let clone = original.copy()

        let originalTrack = original[0].instances[0].track

        // Reassign the clone's instance track to nil.
        clone[0].instances[0].track = nil

        XCTAssertNil(clone[0].instances[0].track)
        XCTAssertTrue(original[0].instances[0].track === originalTrack,
                      "Mutating a cloned instance's track must not affect the original")
    }

    func testAddingInstanceToClonedFrameDoesNotAffectOriginal() {
        let original = makeTestLabels()
        let clone = original.copy()

        let originalCount = original[1].instances.count
        clone[1].instances.append(Instance(skeleton: clone.skeletons[0]))

        XCTAssertEqual(clone[1].instances.count, originalCount + 1)
        XCTAssertEqual(original[1].instances.count, originalCount,
                       "Adding an instance to a cloned frame must not affect the original")
    }

    func testMutatingClonedVideoDoesNotAffectOriginal() {
        let original = makeTestLabels()
        let clone = original.copy()

        let originalName = original.videos[0].persistedFilename
        clone.videos[0].persistedFilename = "changed.mp4"

        XCTAssertEqual(clone.videos[0].persistedFilename, "changed.mp4")
        XCTAssertEqual(original.videos[0].persistedFilename, originalName,
                       "Mutating a cloned video must not affect the original")
    }

    func testMutatingClonedSkeletonDoesNotAffectOriginal() {
        let original = makeTestLabels()
        let clone = original.copy()

        let originalEdgeCount = original.skeletons[0].edges.count
        clone.skeletons[0].addNode(named: "extra")

        XCTAssertEqual(original.skeletons[0].nodes.count, 3,
                       "Mutating a cloned skeleton must not affect the original")
        XCTAssertEqual(original.skeletons[0].edges.count, originalEdgeCount)
    }

    // MARK: - Lazy materialization path

    func testCopyMaterializesLazyLabels() {
        // A minimal lazy store that materializes frames on demand.
        let video = Video(filename: "lazy.mp4")
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "a"), Node(name: "b")])
        let frame = LabeledFrame(video: video, frameIndex: 3, instances: [
            Instance(skeleton: skeleton),
        ])
        let store = TestLazyFrameStore(frames: [frame])
        let labels = Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )
        XCTAssertTrue(labels.isLazy)

        let clone = labels.copy()
        XCTAssertFalse(clone.isLazy, "copy() must materialize before cloning")
        XCTAssertEqual(clone.frameCount, 1)
        XCTAssertEqual(clone[0].frameIndex, 3)
        XCTAssertTrue(clone[0].video === clone.videos[0])
        XCTAssertTrue(clone[0].instances[0].skeleton === clone.skeletons[0])
    }
}

/// A minimal in-test lazy `FrameStore` used to exercise `copy()`'s
/// materialize-first behavior without depending on SleapHDF5.
private final class TestLazyFrameStore: FrameStore, @unchecked Sendable {
    private let frames: [LabeledFrame]

    init(frames: [LabeledFrame]) {
        self.frames = frames
    }

    var count: Int { frames.count }
    func frame(at index: Int) -> LabeledFrame { frames[index] }
    var isLazy: Bool { true }
    func allFrames() -> [LabeledFrame] { frames }
    var totalInstanceCount: Int { frames.reduce(0) { $0 + $1.instances.count } }
    var totalPredictedInstanceCount: Int {
        frames.reduce(0) { $0 + $1.predictedInstances.count }
    }
}

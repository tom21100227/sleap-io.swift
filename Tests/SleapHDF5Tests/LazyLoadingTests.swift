import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// L01-L06: Lazy loading semantics tests.
///
/// These tests require .slp fixture files. Tests that need fixtures will skip
/// gracefully if the fixtures are not yet available.
final class LazyLoadingTests: XCTestCase {

    // MARK: - Fixture helpers

    private func fixtureURL(_ name: String) -> URL? {
        // Look for fixtures relative to the package root
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SleapHDF5Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let url = packageRoot.appendingPathComponent("Tests/Fixtures/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func requireFixture(_ name: String, file: StaticString = #file, line: UInt = #line) throws -> URL {
        guard let url = fixtureURL(name) else {
            throw XCTSkip("Fixture '\(name)' not found — generate fixtures first")
        }
        return url
    }

    private func tempURL(extension ext: String = "slp") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_lazy_\(UUID().uuidString).\(ext)")
    }

    // MARK: - Helpers for in-memory lazy simulation

    /// Creates a mock lazy Labels for testing mutation guards without HDF5.
    /// Uses a simple MockLazyFrameStore that reports isLazy = true.
    private func makeMockLazyLabels() -> Labels {
        let skeleton = Skeleton(name: "fly", nodes: [
            Node(name: "head"),
            Node(name: "thorax"),
        ])
        let video = Video(filename: "test.mp4")
        let track = Track(name: "track1")

        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [
            Instance(skeleton: skeleton, track: track),
        ])

        let store = MockLazyFrameStore(frames: [frame])
        return Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: [track]
        )
    }

    // MARK: - L01: Lazy load default

    func testL01_slpLoadIsLazyByDefault() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)
        XCTAssertTrue(labels.isLazy, "SLP loads should be lazy by default")
    }

    // MARK: - L02: Lazy frame materialization

    func testL02_lazyFrameIsMaterializedOnAccess() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)
        XCTAssertTrue(labels.isLazy)
        XCTAssertGreaterThan(labels.count, 0)

        // Access first frame — this triggers materialization
        let frame = labels[0]
        XCTAssertNotNil(frame)
        XCTAssertGreaterThanOrEqual(frame.frameIndex, 0)
    }

    func testL02_cachedFrameReturnedOnSubsequentAccess() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)

        // Access the same frame twice
        let frame1 = labels[0]
        let frame2 = labels[0]

        XCTAssertTrue(
            frame1 === frame2,
            "The cached object must be returned — identity stability"
        )
    }

    func testL02_identityStableAcrossAllIndices() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)

        // Verify every frame index returns the same object on repeated access
        for i in 0..<min(labels.count, 10) {
            let a = labels[i]
            let b = labels[i]
            XCTAssertTrue(a === b, "labels[\(i)] must be identity-stable")
        }
    }

    // MARK: - L03: Cached frame mutation

    func testL03_editPointsPersistsAcrossAccesses() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)
        guard labels.count > 0, labels[0].instances.count > 0 else {
            throw XCTSkip("Fixture has no instances to mutate")
        }

        let frame = labels[0]
        let inst = frame.instances[0]

        // Mutate a point
        let originalX = inst.points[0].x
        inst.points[0] = Point(x: 12345.0, y: 67890.0, visible: true)

        // Re-access the frame from labels — same object, so mutation persists
        let frameAgain = labels[0]
        XCTAssertTrue(frameAgain === frame)
        XCTAssertEqual(frameAgain.instances[0].points[0].x, 12345.0, accuracy: 1e-4)
        XCTAssertEqual(frameAgain.instances[0].points[0].y, 67890.0, accuracy: 1e-4)
        XCTAssertNotEqual(originalX, 12345.0, "Sanity check: original value should differ")
    }

    func testL03_changeTrackAssignmentPersists() async throws {
        let url = try requireFixture("dense_predictions_v1_5.slp")

        let labels = try await Labels.load(from: url)
        guard labels.count > 0, labels[0].instances.count > 0 else {
            throw XCTSkip("Fixture has no instances")
        }

        let frame = labels[0]
        let inst = frame.instances[0]
        let newTrack = Track(name: "test_reassign")
        inst.track = newTrack

        let frameAgain = labels[0]
        XCTAssertTrue(frameAgain.instances[0].track === newTrack)
    }

    func testL03_addInstanceWithinCachedFrame() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)
        guard labels.count > 0 else {
            throw XCTSkip("Fixture has no frames")
        }

        let frame = labels[0]
        let skeleton = labels.skeletons[0]
        let newInst = Instance(skeleton: skeleton)
        let originalCount = frame.instances.count
        frame.instances.append(newInst)

        let frameAgain = labels[0]
        XCTAssertEqual(frameAgain.instances.count, originalCount + 1)
        XCTAssertTrue(frameAgain.instances.last === newInst)
    }

    func testL03_removeInstanceWithinCachedFrame() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)
        guard labels.count > 0, labels[0].instances.count > 0 else {
            throw XCTSkip("Fixture has no instances")
        }

        let frame = labels[0]
        let originalCount = frame.instances.count
        frame.instances.removeLast()

        let frameAgain = labels[0]
        XCTAssertEqual(frameAgain.instances.count, originalCount - 1)
    }

    // MARK: - L04: Structural mutation guard

    func testL04_addFrameThrowsWhileLazy() {
        let labels = makeMockLazyLabels()
        XCTAssertTrue(labels.isLazy)

        let newFrame = LabeledFrame(
            video: Video(filename: "new.mp4"),
            frameIndex: 99
        )

        XCTAssertThrowsError(try labels.addFrame(newFrame)) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    func testL04_removeFrameThrowsWhileLazy() {
        let labels = makeMockLazyLabels()
        let frame = labels[0]

        XCTAssertThrowsError(try labels.removeFrame(frame)) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    func testL04_clearPredictionsThrowsWhileLazy() {
        let labels = makeMockLazyLabels()

        XCTAssertThrowsError(try labels.clearPredictions()) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    func testL04_removeTrackThrowsWhileLazy() {
        let labels = makeMockLazyLabels()
        let track = labels.tracks[0]

        XCTAssertThrowsError(try labels.removeTrack(track)) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    func testL04_mergeThrowsWhileLazy() {
        let labels = makeMockLazyLabels()
        let other = Labels()

        XCTAssertThrowsError(try labels.merge(from: other)) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    // MARK: - L05: Identity-table mutation guard

    func testL05_setVideosThrowsWhileLazy() {
        let labels = makeMockLazyLabels()

        XCTAssertThrowsError(try labels.setVideos([Video(filename: "new.mp4")])) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    func testL05_setSkeletonsThrowsWhileLazy() {
        let labels = makeMockLazyLabels()

        XCTAssertThrowsError(try labels.setSkeletons([Skeleton(name: "new")])) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    func testL05_setTracksThrowsWhileLazy() {
        let labels = makeMockLazyLabels()

        XCTAssertThrowsError(try labels.setTracks([Track(name: "new")])) { error in
            guard case SleapIOError.mutationWhileLazy = error else {
                XCTFail("Expected mutationWhileLazy, got: \(error)")
                return
            }
        }
    }

    // MARK: - L06: Materialize transition

    func testL06_materializeTransitionsToEager() {
        let labels = makeMockLazyLabels()
        XCTAssertTrue(labels.isLazy)

        labels.materialize()

        XCTAssertFalse(labels.isLazy, "After materialize(), isLazy must be false")
    }

    func testL06_allFramesAvailableAfterMaterialize() {
        let labels = makeMockLazyLabels()
        let originalCount = labels.count

        labels.materialize()

        XCTAssertEqual(labels.count, originalCount)
        for i in 0..<labels.count {
            XCTAssertNotNil(labels[i])
        }
    }

    func testL06_structuralMutationsWorkAfterMaterialize() {
        let labels = makeMockLazyLabels()
        labels.materialize()

        // addFrame should now succeed
        let skeleton = labels.skeletons[0]
        let video = labels.videos[0]
        let newFrame = LabeledFrame(video: video, frameIndex: 99, instances: [
            Instance(skeleton: skeleton),
        ])

        XCTAssertNoThrow(try labels.addFrame(newFrame))
        XCTAssertEqual(labels.count, 2)
    }

    func testL06_identityTableMutationsWorkAfterMaterialize() {
        let labels = makeMockLazyLabels()
        labels.materialize()

        let newVideo = Video(filename: "new.mp4")
        XCTAssertNoThrow(try labels.setVideos([newVideo]))
        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels.videos[0] === newVideo)

        XCTAssertNoThrow(try labels.setSkeletons([Skeleton(name: "new")]))
        XCTAssertNoThrow(try labels.setTracks([Track(name: "new")]))
    }

    func testL06_materializeWithRealFixture() async throws {
        let url = try requireFixture("sparse_v1_5.slp")

        let labels = try await Labels.load(from: url)
        XCTAssertTrue(labels.isLazy)

        // Access a few frames first to populate the cache
        if labels.count > 0 { let _ = labels[0] }
        if labels.count > 1 { let _ = labels[1] }

        labels.materialize()

        XCTAssertFalse(labels.isLazy)

        // All frames should be accessible
        for i in 0..<labels.count {
            XCTAssertNotNil(labels[i])
        }

        // Structural mutations should now work
        let skeleton = labels.skeletons[0]
        let video = labels.videos[0]
        let newFrame = LabeledFrame(video: video, frameIndex: 99999, instances: [
            Instance(skeleton: skeleton),
        ])
        XCTAssertNoThrow(try labels.addFrame(newFrame))
    }

    func testLazyLoadPreservesNegativeFramesAcrossSaveRoundTrip() async throws {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "body")])
        let video = Video(filename: "negative.mp4")

        let negativeFrame = LabeledFrame(video: video, frameIndex: 7, isNegative: true)
        let positiveFrame = LabeledFrame(
            video: video,
            frameIndex: 8,
            instances: [Instance(skeleton: skeleton)]
        )

        let original = Labels(
            frameStore: EagerFrameStore(frames: [negativeFrame, positiveFrame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: []
        )

        let firstURL = tempURL()
        let secondURL = tempURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        try await original.save(to: firstURL)

        let lazy = try await Labels.load(from: firstURL)
        XCTAssertTrue(lazy.isLazy)

        let lazyNegative = try XCTUnwrap(lazy.frame(for: lazy.videos[0], at: 7))
        let lazyPositive = try XCTUnwrap(lazy.frame(for: lazy.videos[0], at: 8))
        XCTAssertTrue(lazyNegative.isNegative)
        XCTAssertFalse(lazyPositive.isNegative)

        try await lazy.save(to: secondURL)

        let eager = try await Labels.loadEager(from: secondURL)
        let eagerNegative = try XCTUnwrap(eager.frame(for: eager.videos[0], at: 7))
        let eagerPositive = try XCTUnwrap(eager.frame(for: eager.videos[0], at: 8))
        XCTAssertTrue(eagerNegative.isNegative)
        XCTAssertFalse(eagerPositive.isNegative)
    }
}

// MARK: - Mock lazy frame store for testing mutation guards

/// A simple mock that wraps eager frames but reports isLazy = true,
/// enabling tests for mutation guards without requiring HDF5 fixtures.
private final class MockLazyFrameStore: FrameStore, @unchecked Sendable {
    private let frames: [LabeledFrame]
    private var cache: [Int: LabeledFrame] = [:]

    init(frames: [LabeledFrame]) {
        self.frames = frames
    }

    var count: Int { frames.count }

    func frame(at index: Int) -> LabeledFrame {
        if let cached = cache[index] { return cached }
        let f = frames[index]
        cache[index] = f
        return f
    }

    var isLazy: Bool { true }

    func allFrames() -> [LabeledFrame] { frames }

    var totalInstanceCount: Int {
        frames.reduce(0) { $0 + $1.instances.count }
    }

    var totalPredictedInstanceCount: Int {
        frames.reduce(0) { $0 + $1.predictedInstances.count }
    }
}

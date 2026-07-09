import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// E7 (#44/#45/#46): round-trip fidelity for the SLP annotation datasets —
/// `/bboxes` (bounding boxes), `/centroids` (centroids), and `/identities_json`
/// (identities). Each test builds a `Labels`, saves it to a temp `.slp`, reloads
/// eagerly, and asserts the modeled annotations survive intact.
///
/// The eager path (`Labels.loadEager`) is used deliberately: it is the path that
/// materializes these annotation arrays (see `SLPReader.readFromFile`).
final class AnnotationDatasetTests: XCTestCase {

    // MARK: - Fixtures

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_annotation_\(UUID().uuidString).slp")
    }

    /// Minimal but valid `Labels`: one skeleton, one video, one track, and one
    /// frame with a single instance — enough for the writer to emit a well-formed
    /// file that the reader can round-trip.
    private func makeBaseLabels() -> Labels {
        let skeleton = Skeleton(name: "animal", nodes: [Node(name: "head"), Node(name: "tail")])
        let video = Video(filename: "annotations.mp4")
        let track = Track(name: "track_0")
        let instance = Instance(
            skeleton: skeleton,
            points: PointsArray(points: [
                Point(x: 1, y: 2, visible: true, complete: true),
                Point(x: 3, y: 4, visible: true, complete: true),
            ]),
            track: track)
        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [instance])
        return Labels(
            frameStore: EagerFrameStore(frames: [frame]),
            videos: [video],
            skeletons: [skeleton],
            tracks: [track])
    }

    private func save(_ labels: Labels) async throws -> URL {
        let url = tempURL()
        try await labels.save(to: url)
        return url
    }

    // MARK: - Identities (#46)

    func testIdentitiesRoundTrip() async throws {
        let labels = makeBaseLabels()
        labels.identities = [
            Identity(name: "mouse_A", color: "#e6194b", metadata: [
                "species": .string("mouse"),
                "cage": .int(3),
                "weight": .double(1.5),
            ]),
            Identity(name: "mouse_B", color: nil, metadata: [:]),
        ]

        let url = try await save(labels)
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try await Labels.loadEager(from: url)
        XCTAssertEqual(reloaded.identities.count, 2)
        XCTAssertEqual(reloaded.identities, labels.identities)

        let first = reloaded.identities[0]
        XCTAssertEqual(first.name, "mouse_A")
        XCTAssertEqual(first.color, "#e6194b")
        XCTAssertEqual(first.metadata["species"], .string("mouse"))
        XCTAssertEqual(first.metadata["cage"], .int(3))
        XCTAssertEqual(first.metadata["weight"], .double(1.5))
        // name/color must not leak into metadata.
        XCTAssertNil(first.metadata["name"])
        XCTAssertNil(first.metadata["color"])

        XCTAssertEqual(reloaded.identities[1].name, "mouse_B")
        XCTAssertNil(reloaded.identities[1].color)
        XCTAssertTrue(reloaded.identities[1].metadata.isEmpty)
    }

    // MARK: - Bounding boxes (#44)

    func testBoundingBoxesRoundTrip() async throws {
        let labels = makeBaseLabels()
        let user = BoundingBox.user(
            xCenter: 100, yCenter: 50, width: 40, height: 20,
            videoIndex: 0, frameIndex: 0, trackIndex: 0,
            category: "mouse", name: "box1", source: "manual")
        let predicted = BoundingBox.predicted(
            xCenter: 200, yCenter: 80, width: 30, height: 30, score: 0.87,
            videoIndex: 0, frameIndex: 0, trackIndex: 0, instanceIndex: 0)
        let rotated = BoundingBox.user(
            xCenter: 10, yCenter: 10, width: 8, height: 4, angle: 0.5)
        labels.bboxes = [user, predicted, rotated]

        let url = try await save(labels)
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try await Labels.loadEager(from: url)
        XCTAssertEqual(reloaded.bboxes.count, 3)
        XCTAssertEqual(reloaded.bboxes, labels.bboxes)

        let u = reloaded.bboxes[0]
        XCTAssertEqual(u.xCenter, 100)
        XCTAssertEqual(u.yCenter, 50)
        XCTAssertEqual(u.width, 40)
        XCTAssertEqual(u.height, 20)
        XCTAssertFalse(u.isPredicted)
        XCTAssertNil(u.score)
        XCTAssertEqual(u.videoIndex, 0)
        XCTAssertEqual(u.frameIndex, 0)
        XCTAssertEqual(u.trackIndex, 0)
        XCTAssertNil(u.instanceIndex)
        XCTAssertEqual(u.category, "mouse")
        XCTAssertEqual(u.name, "box1")
        XCTAssertEqual(u.source, "manual")

        let p = reloaded.bboxes[1]
        XCTAssertTrue(p.isPredicted)
        XCTAssertEqual(p.score ?? 0, 0.87, accuracy: 1e-6)
        XCTAssertEqual(p.instanceIndex, 0)
        XCTAssertNil(p.category)

        let r = reloaded.bboxes[2]
        XCTAssertTrue(r.isRotated)
        XCTAssertEqual(r.angle, 0.5, accuracy: 1e-12)
    }

    func testGetBboxesFlattenedAndFiltered() async throws {
        let labels = makeBaseLabels()
        // Axis-aligned box centered at (100, 50), size 40x20 -> bounds 80,40,120,60.
        labels.bboxes = [
            BoundingBox.user(xCenter: 100, yCenter: 50, width: 40, height: 20,
                             videoIndex: 0, frameIndex: 0),
            BoundingBox.user(xCenter: 10, yCenter: 10, width: 4, height: 4,
                             videoIndex: 0, frameIndex: 7),
        ]

        let all = labels.getBboxes()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0], [80, 40, 120, 60])

        // Filter by frame index.
        let frame0 = labels.getBboxes(video: labels.videos[0], frameIndex: 0)
        XCTAssertEqual(frame0.count, 1)
        XCTAssertEqual(frame0[0], [80, 40, 120, 60])
    }

    // MARK: - Centroids (#45)

    func testCentroidsRoundTrip() async throws {
        let labels = makeBaseLabels()
        let user = Centroid.user(
            x: 12.5, y: 34.5, videoIndex: 0, frameIndex: 0, trackIndex: 0, name: "c1")
        let predicted = Centroid.predicted(
            x: 50, y: 60, score: 0.9, videoIndex: 0, frameIndex: 0)
        labels.centroids = [user, predicted]

        let url = try await save(labels)
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try await Labels.loadEager(from: url)
        XCTAssertEqual(reloaded.centroids.count, 2)
        XCTAssertEqual(reloaded.centroids, labels.centroids)

        let u = reloaded.centroids[0]
        XCTAssertEqual(u.x, 12.5)
        XCTAssertEqual(u.y, 34.5)
        XCTAssertFalse(u.isPredicted)
        XCTAssertNil(u.score)
        XCTAssertEqual(u.videoIndex, 0)
        XCTAssertEqual(u.trackIndex, 0)
        XCTAssertEqual(u.name, "c1")

        let p = reloaded.centroids[1]
        XCTAssertTrue(p.isPredicted)
        XCTAssertEqual(p.score ?? 0, 0.9, accuracy: 1e-6)
        XCTAssertNil(p.trackIndex)
    }

    func testGetCentroidsFlattened() async throws {
        let labels = makeBaseLabels()
        labels.centroids = [
            Centroid.user(x: 12.5, y: 34.5, videoIndex: 0, frameIndex: 0),
        ]
        let flat = labels.getCentroids()
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0], [12.5, 34.5])
    }

    // MARK: - Combined + empty

    func testAllAnnotationTypesTogetherRoundTrip() async throws {
        let labels = makeBaseLabels()
        labels.identities = [Identity(name: "id0", color: "#123456")]
        labels.bboxes = [BoundingBox.user(xCenter: 5, yCenter: 5, width: 2, height: 2,
                                          videoIndex: 0, frameIndex: 0)]
        labels.centroids = [Centroid.predicted(x: 1, y: 1, score: 0.5, videoIndex: 0, frameIndex: 0)]

        let url = try await save(labels)
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try await Labels.loadEager(from: url)
        XCTAssertEqual(reloaded.identities, labels.identities)
        XCTAssertEqual(reloaded.bboxes, labels.bboxes)
        XCTAssertEqual(reloaded.centroids, labels.centroids)
    }

    // MARK: - Lazy-load path (regression guard for the default load path)

    /// Guards that the DEFAULT (lazy) load path populates the annotation arrays,
    /// not just the eager path. The lazy reader lives in `LazyFrameList.swift`
    /// (`readLazyFromFile`) and previously did not read these datasets.
    func testAllAnnotationTypesRoundTripViaLazyLoad() async throws {
        let labels = makeBaseLabels()
        labels.identities = [Identity(name: "id0", color: "#123456")]
        labels.bboxes = [BoundingBox.user(xCenter: 5, yCenter: 5, width: 2, height: 2,
                                          videoIndex: 0, frameIndex: 0)]
        labels.centroids = [Centroid.predicted(x: 1, y: 1, score: 0.5, videoIndex: 0, frameIndex: 0)]

        let url = try await save(labels)
        defer { try? FileManager.default.removeItem(at: url) }

        // `Labels.load` is the default, lazy path (contrast with `loadEager`).
        let reloaded = try await Labels.load(from: url)
        XCTAssertTrue(reloaded.isLazy, "default load should use the lazy store")
        XCTAssertEqual(reloaded.identities, labels.identities)
        XCTAssertEqual(reloaded.bboxes, labels.bboxes)
        XCTAssertEqual(reloaded.centroids, labels.centroids)
    }

    func testNoAnnotationsRoundTripsEmpty() async throws {
        let labels = makeBaseLabels()

        let url = try await save(labels)
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try await Labels.loadEager(from: url)
        XCTAssertTrue(reloaded.identities.isEmpty)
        XCTAssertTrue(reloaded.bboxes.isEmpty)
        XCTAssertTrue(reloaded.centroids.isEmpty)
        XCTAssertTrue(reloaded.getBboxes().isEmpty)
        XCTAssertTrue(reloaded.getCentroids().isEmpty)
        XCTAssertTrue(reloaded.getLabelImages().isEmpty)
    }
}

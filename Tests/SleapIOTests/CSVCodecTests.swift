import XCTest
@testable import SleapIO

/// CSV codec tests (V01-V07, P02, P04, P06, round-trip).
final class CSVCodecTests: XCTestCase {

    // MARK: - Helpers

    /// Write a CSV string to a temp file and return the path.
    private func writeTempCSV(_ content: String, filename: String = "test.csv") -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(filename).path
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Return a temp directory path for writing output.
    private func tempOutputPath(filename: String = "output.csv") -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename).path
    }

    /// Build a minimal Labels with user instances for export tests.
    private func makeLabels(
        skeletonName: String = "fly",
        nodeNames: [String] = ["head", "thorax", "abdomen"],
        videoFilename: String = "test.mp4",
        frameIndex: Int = 0,
        instancePoints: [[Point]],
        tracks: [Track?] = [],
        addEdge: Bool = false
    ) -> Labels {
        let skeleton = Skeleton(name: skeletonName, nodes: nodeNames.map { Node(name: $0) })
        if addEdge {
            skeleton.addEdge(from: skeleton.nodes[0], to: skeleton.nodes[1])
        }
        let video = Video(filename: videoFilename)
        var instances: [Instance] = []
        for (i, pts) in instancePoints.enumerated() {
            let pa = PointsArray(points: pts)
            let track = i < tracks.count ? tracks[i] : nil
            instances.append(Instance(skeleton: skeleton, points: pa, track: track))
        }
        let frame = LabeledFrame(video: video, frameIndex: frameIndex, instances: instances)
        let store = EagerFrameStore(frames: [frame])
        let allTracks = tracks.compactMap { $0 }
        return Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: allTracks
        )
    }

    /// Build a Labels with a predicted instance for export tests.
    private func makePredictedLabels(
        skeletonName: String = "fly",
        nodeNames: [String] = ["head", "thorax"],
        videoFilename: String = "test.mp4",
        frameIndex: Int = 0,
        points: [PredictedPoint],
        instanceScore: Float = 0.9,
        track: Track? = nil,
        trackingScore: Float? = nil
    ) -> Labels {
        let skeleton = Skeleton(name: skeletonName, nodes: nodeNames.map { Node(name: $0) })
        let video = Video(filename: videoFilename)
        let ppa = PredictedPointsArray(points: points)
        let inst = PredictedInstance(
            skeleton: skeleton,
            points: ppa,
            score: instanceScore,
            track: track,
            trackingScore: trackingScore
        )
        let frame = LabeledFrame(video: video, frameIndex: frameIndex, instances: [inst])
        let store = EagerFrameStore(frames: [frame])
        let allTracks = track.map { [$0] } ?? []
        return Labels(
            frameStore: store,
            videos: [video],
            skeletons: [skeleton],
            tracks: allTracks
        )
    }

    /// Standard header for the canonical CSV format.
    private let fullHeader = "video,frame_idx,skeleton,instance,node,x,y,visible,complete,track,instance_type,instance_score,point_score,tracking_score"
    private let minHeader = "video,frame_idx,skeleton,instance,node,x,y,visible"

    // MARK: - V01: CSV grouping semantics

    func testGroupingByVideoFrameSkeletonInstance() throws {
        // V01: Rows with the same (video, frame_idx, skeleton, instance) tuple form one Instance.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true
        vid.mp4,0,fly,0,thorax,30.0,40.0,true
        vid.mp4,0,fly,1,head,50.0,60.0,true
        vid.mp4,0,fly,1,thorax,70.0,80.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertEqual(labels.frameCount, 1)
        let frame = labels[0]
        XCTAssertEqual(frame.instances.count, 2, "Two distinct instance values should produce two instances")

        // First instance should have head=(10,20) thorax=(30,40)
        let inst0 = frame.instances[0]
        XCTAssertEqual(inst0.points[0].x, 10.0, accuracy: 1e-4)
        XCTAssertEqual(inst0.points[0].y, 20.0, accuracy: 1e-4)
        XCTAssertEqual(inst0.points[1].x, 30.0, accuracy: 1e-4)

        // Second instance should have head=(50,60) thorax=(70,80)
        let inst1 = frame.instances[1]
        XCTAssertEqual(inst1.points[0].x, 50.0, accuracy: 1e-4)
        XCTAssertEqual(inst1.points[1].x, 70.0, accuracy: 1e-4)
    }

    // MARK: - V02: CSV skeleton reconstruction

    func testSkeletonCreatedPerDistinctName() throws {
        // V02: Distinct skeleton values create distinct Skeleton objects.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,1.0,2.0,true
        vid.mp4,0,mouse,0,nose,3.0,4.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertEqual(labels.skeletons.count, 2)
        let names = Set(labels.skeletons.map(\.name))
        XCTAssertEqual(names, Set(["fly", "mouse"]))
    }

    func testNodeOrderIsFirstSeen() throws {
        // V02: Node order matches first-seen order within each skeleton.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,thorax,1.0,2.0,true
        vid.mp4,0,fly,0,head,3.0,4.0,true
        vid.mp4,0,fly,0,abdomen,5.0,6.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let skeleton = labels.skeletons[0]
        XCTAssertEqual(skeleton.nodes.map(\.name), ["thorax", "head", "abdomen"],
                       "Node order must match first-seen order in the CSV")
    }

    func testImportedSkeletonsAreEdgeless() throws {
        // V02: No edges on imported skeletons (CSV cannot represent edges).
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,1.0,2.0,true
        vid.mp4,0,fly,0,thorax,3.0,4.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertTrue(labels.skeletons[0].edges.isEmpty, "Imported skeletons must be edgeless")
        XCTAssertTrue(labels.skeletons[0].symmetries.isEmpty, "Imported skeletons must have no symmetries")
    }

    // MARK: - V03: Missing-node behavior

    func testMissingNodeFilledWithNaN() throws {
        // V03: If a node is absent from rows for an instance, it gets NaN coords, visible=false, complete=false.
        // Instance 0 has head but not thorax. Instance 1 provides thorax so the skeleton has both nodes.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true
        vid.mp4,0,fly,1,head,30.0,40.0,true
        vid.mp4,0,fly,1,thorax,50.0,60.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let frame = labels[0]
        // Instance 0 should have thorax filled with NaN
        let inst0 = frame.instances[0]
        let skeleton = inst0.skeleton
        let thoraxIdx = skeleton.index(of: skeleton.node(named: "thorax")!)!
        let thoraxPoint = inst0.points[thoraxIdx]
        XCTAssertTrue(thoraxPoint.x.isNaN, "Missing node x should be NaN")
        XCTAssertTrue(thoraxPoint.y.isNaN, "Missing node y should be NaN")
        XCTAssertFalse(thoraxPoint.visible, "Missing node visible should be false")
        XCTAssertFalse(thoraxPoint.complete, "Missing node complete should be false")
    }

    func testWriterEmitsAllNodes() throws {
        // V03: Export emits one row per node even for NaN points.
        let points: [Point] = [
            Point(x: 10, y: 20, visible: true),
            Point(x: .nan, y: .nan, visible: false),
            Point(x: 50, y: 60, visible: true),
        ]
        let labels = makeLabels(instancePoints: [points])
        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Header + 3 node rows = 4 lines
        XCTAssertEqual(lines.count, 4, "Writer must emit one row per node including NaN points")
    }

    // MARK: - V04: Predicted-instance behavior

    func testInstanceTypePredicatedCreatesPredictedInstance() throws {
        // V04: instance_type=="predicted" creates PredictedInstance.
        let csv = """
        \(fullHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true,true,,predicted,0.95,0.8,
        vid.mp4,0,fly,0,thorax,30.0,40.0,true,true,,predicted,0.95,0.7,
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let inst = labels[0].instances[0]
        XCTAssertTrue(inst is PredictedInstance, "instance_type='predicted' must create PredictedInstance")
    }

    func testInstanceScoreMapsToScore() throws {
        // V04: instance_score column maps to PredictedInstance.score.
        let csv = """
        \(fullHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true,true,,predicted,0.85,0.9,
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let pred = labels[0].instances[0] as! PredictedInstance
        XCTAssertEqual(pred.score, 0.85, accuracy: 1e-4)
    }

    func testPointScoreMapsToPointScore() throws {
        // V04: point_score column maps to per-point score.
        let csv = """
        \(fullHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true,true,,predicted,0.9,0.75,
        vid.mp4,0,fly,0,thorax,30.0,40.0,true,true,,predicted,0.9,0.82,
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let pred = labels[0].instances[0] as! PredictedInstance
        XCTAssertEqual(pred.predictedPoints[0].score, 0.75, accuracy: 1e-4)
        XCTAssertEqual(pred.predictedPoints[1].score, 0.82, accuracy: 1e-4)
    }

    func testTrackingScoreMapped() throws {
        // V04: tracking_score column maps to Instance.trackingScore.
        let csv = """
        \(fullHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true,true,,predicted,0.9,0.8,0.55
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let inst = labels[0].instances[0]
        XCTAssertEqual(Double(inst.trackingScore ?? 0), 0.55, accuracy: 1e-4)
    }

    func testNoScoreColumnsCreatesUserInstance() throws {
        // V04: No prediction columns creates plain Instance (not PredictedInstance).
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,10.0,20.0,true
        vid.mp4,0,fly,0,thorax,30.0,40.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let inst = labels[0].instances[0]
        XCTAssertFalse(inst is PredictedInstance, "No prediction columns should create a plain Instance")
    }

    // MARK: - V05: Track behavior

    func testSameTrackStringSharesTrackObject() throws {
        // V05: Rows with the same track value share one Track (===).
        let csv = """
        video,frame_idx,skeleton,instance,node,x,y,visible,track
        vid.mp4,0,fly,0,head,10.0,20.0,true,animal_0
        vid.mp4,0,fly,0,thorax,30.0,40.0,true,animal_0
        vid.mp4,1,fly,0,head,50.0,60.0,true,animal_0
        vid.mp4,1,fly,0,thorax,70.0,80.0,true,animal_0
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        let track0 = labels[0].instances[0].track
        let track1 = labels[1].instances[0].track
        XCTAssertNotNil(track0)
        XCTAssertNotNil(track1)
        XCTAssertTrue(track0 === track1, "Same track string must produce the same Track object")
    }

    func testEmptyTrackStringMeansNoTrack() throws {
        // V05: Empty track string means instance.track == nil.
        let csv = """
        video,frame_idx,skeleton,instance,node,x,y,visible,track
        vid.mp4,0,fly,0,head,10.0,20.0,true,
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertNil(labels[0].instances[0].track, "Empty track string must produce nil track")
    }

    // MARK: - V06: Export behavior

    func testExportOneRowPerNode() throws {
        // V06: Export emits nodeCount rows per instance.
        let points: [Point] = [
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: true),
            Point(x: 5, y: 6, visible: true),
        ]
        let labels = makeLabels(instancePoints: [points])
        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "Header + 3 nodes = 4 lines")
    }

    func testExportHeaderPresent() throws {
        // V06: First row is a header with required columns.
        let labels = makeLabels(instancePoints: [[
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: true),
            Point(x: 5, y: 6, visible: true),
        ]])
        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let header = content.components(separatedBy: "\n").first!
        let columns = header.components(separatedBy: ",")

        // Required columns must be present
        for required in ["video", "frame_idx", "skeleton", "instance", "node", "x", "y", "visible"] {
            XCTAssertTrue(columns.contains(required), "Header must contain '\(required)'")
        }
    }

    func testExportInstanceZeroBasedPerFrame() throws {
        // V06: Instance column is 0-based within each (video, frame_idx) group.
        let points1: [Point] = [
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: true),
            Point(x: 5, y: 6, visible: true),
        ]
        let points2: [Point] = [
            Point(x: 10, y: 20, visible: true),
            Point(x: 30, y: 40, visible: true),
            Point(x: 50, y: 60, visible: true),
        ]
        let labels = makeLabels(instancePoints: [points1, points2])
        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let instanceCol = header.firstIndex(of: "instance")!

        // First instance's rows should have instance=0
        let row1 = lines[1].components(separatedBy: ",")
        XCTAssertEqual(row1[instanceCol], "0")

        // Second instance's rows should have instance=1
        let row4 = lines[4].components(separatedBy: ",")
        XCTAssertEqual(row4[instanceCol], "1")
    }

    func testExportInstanceType() throws {
        // V06: User instances -> "user", predicted -> "predicted".
        // Build a labels with both user and predicted instances.
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head"), Node(name: "thorax")])
        let video = Video(filename: "test.mp4")

        let userPoints = PointsArray(points: [
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: true),
        ])
        let userInst = Instance(skeleton: skeleton, points: userPoints)

        let predPoints = PredictedPointsArray(points: [
            PredictedPoint(x: 10, y: 20, score: 0.9),
            PredictedPoint(x: 30, y: 40, score: 0.8),
        ])
        let predInst = PredictedInstance(skeleton: skeleton, points: predPoints, score: 0.95)

        let frame = LabeledFrame(video: video, frameIndex: 0, instances: [userInst, predInst])
        let store = EagerFrameStore(frames: [frame])
        let labels = Labels(frameStore: store, videos: [video], skeletons: [skeleton], tracks: [])

        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let typeCol = header.firstIndex(of: "instance_type")!

        // User instance rows (lines 1-2) should say "user"
        XCTAssertEqual(lines[1].components(separatedBy: ",")[typeCol], "user")
        XCTAssertEqual(lines[2].components(separatedBy: ",")[typeCol], "user")

        // Predicted instance rows (lines 3-4) should say "predicted"
        XCTAssertEqual(lines[3].components(separatedBy: ",")[typeCol], "predicted")
        XCTAssertEqual(lines[4].components(separatedBy: ",")[typeCol], "predicted")
    }

    func testExportTrackName() throws {
        // V06: Track name written, empty string if no track.
        let track = Track(name: "animal_0")
        let points1 = [Point(x: 1, y: 2, visible: true), Point(x: 3, y: 4, visible: true), Point(x: 5, y: 6, visible: true)]
        let points2 = [Point(x: 10, y: 20, visible: true), Point(x: 30, y: 40, visible: true), Point(x: 50, y: 60, visible: true)]
        let labels = makeLabels(instancePoints: [points1, points2], tracks: [track, nil])
        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let trackCol = header.firstIndex(of: "track")!

        // First instance (with track) should have "animal_0"
        XCTAssertEqual(lines[1].components(separatedBy: ",")[trackCol], "animal_0")

        // Second instance (no track) should have empty string
        XCTAssertEqual(lines[4].components(separatedBy: ",")[trackCol], "")
    }

    func testExportNumericPrecision() throws {
        // V06: Coordinates round-trip within Float precision.
        let x: Float = 123.456
        let y: Float = 789.012
        let labels = makeLabels(
            nodeNames: ["pt"],
            instancePoints: [[Point(x: x, y: y, visible: true)]]
        )
        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)

        let content = try String(contentsOfFile: outPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let xCol = header.firstIndex(of: "x")!
        let yCol = header.firstIndex(of: "y")!

        let row = lines[1].components(separatedBy: ",")
        let readX = Float(row[xCol])!
        let readY = Float(row[yCol])!
        XCTAssertEqual(readX, x, accuracy: 1e-3, "X coordinate must round-trip within Float precision")
        XCTAssertEqual(readY, y, accuracy: 1e-3, "Y coordinate must round-trip within Float precision")
    }

    // MARK: - V07: Losses

    func testEdgesLostOnRoundTrip() throws {
        // V07: Skeleton with edges -> export -> import -> edgeless.
        let labels = makeLabels(
            nodeNames: ["head", "thorax", "abdomen"],
            instancePoints: [[
                Point(x: 1, y: 2, visible: true),
                Point(x: 3, y: 4, visible: true),
                Point(x: 5, y: 6, visible: true),
            ]],
            addEdge: true
        )
        // Verify the source has edges
        XCTAssertFalse(labels.skeletons[0].edges.isEmpty, "Source skeleton should have edges")

        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)
        let reimported = try CSVCodec.read(from: outPath)

        XCTAssertTrue(reimported.skeletons[0].edges.isEmpty,
                       "Edges must be lost after CSV round-trip")
    }

    // MARK: - Round-trip tests

    func testRoundTripPreservesCoordinates() throws {
        // Round-trip: write then read preserves point coordinates.
        let x: Float = 42.5
        let y: Float = 99.75
        let labels = makeLabels(
            nodeNames: ["head", "thorax"],
            instancePoints: [[
                Point(x: x, y: y, visible: true, complete: true),
                Point(x: 200, y: 300, visible: false, complete: false),
            ]]
        )

        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)
        let reimported = try CSVCodec.read(from: outPath)

        let inst = reimported[0].instances[0]
        XCTAssertEqual(inst.points[0].x, x, accuracy: 1e-3)
        XCTAssertEqual(inst.points[0].y, y, accuracy: 1e-3)
        XCTAssertEqual(inst.points[1].x, 200, accuracy: 1e-3)
        XCTAssertEqual(inst.points[1].y, 300, accuracy: 1e-3)
    }

    func testRoundTripPreservesMultipleInstances() throws {
        // Round-trip: multiple instances per frame survive.
        let points1 = [
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: true),
        ]
        let points2 = [
            Point(x: 10, y: 20, visible: true),
            Point(x: 30, y: 40, visible: true),
        ]
        let labels = makeLabels(nodeNames: ["head", "thorax"], instancePoints: [points1, points2])

        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)
        let reimported = try CSVCodec.read(from: outPath)

        XCTAssertEqual(reimported[0].instances.count, 2)
        // Verify coordinates distinguish the instances
        let inst0 = reimported[0].instances[0]
        let inst1 = reimported[0].instances[1]
        XCTAssertEqual(inst0.points[0].x, 1, accuracy: 1e-3)
        XCTAssertEqual(inst1.points[0].x, 10, accuracy: 1e-3)
    }

    func testRoundTripPreservesTrackAssignment() throws {
        // Round-trip: tracks survive.
        let track = Track(name: "animal_0")
        let points = [
            Point(x: 1, y: 2, visible: true),
            Point(x: 3, y: 4, visible: true),
        ]
        let labels = makeLabels(nodeNames: ["head", "thorax"], instancePoints: [points], tracks: [track])

        let outPath = tempOutputPath()
        try CSVCodec.write(labels, to: outPath)
        let reimported = try CSVCodec.read(from: outPath)

        let inst = reimported[0].instances[0]
        XCTAssertNotNil(inst.track)
        XCTAssertEqual(inst.track?.name, "animal_0")
    }

    // MARK: - Error handling (P06)

    func testNonexistentFileThrows() throws {
        // P06: Nonexistent input path throws SleapIOError.fileNotFound.
        let bogusPath = "/tmp/does_not_exist_\(UUID().uuidString).csv"
        XCTAssertThrowsError(try CSVCodec.read(from: bogusPath)) { error in
            guard case SleapIOError.fileNotFound = error else {
                XCTFail("Expected SleapIOError.fileNotFound, got \(error)")
                return
            }
        }
    }

    func testMissingRequiredColumnThrows() throws {
        // P06: CSV without "x" column throws SleapIOError.corruptData.
        let csv = """
        video,frame_idx,skeleton,instance,node,y,visible
        vid.mp4,0,fly,0,head,20.0,true
        """
        let path = writeTempCSV(csv)
        XCTAssertThrowsError(try CSVCodec.read(from: path)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    func testEmptyCSVThrows() throws {
        // P06: Empty file or header-only throws SleapIOError.corruptData.
        let csv = ""
        let path = writeTempCSV(csv)
        XCTAssertThrowsError(try CSVCodec.read(from: path)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    func testHeaderOnlyCSVThrows() throws {
        // P06: Header-only CSV (no data rows) throws SleapIOError.corruptData.
        let csv = "\(minHeader)\n"
        let path = writeTempCSV(csv)
        XCTAssertThrowsError(try CSVCodec.read(from: path)) { error in
            guard case SleapIOError.corruptData = error else {
                XCTFail("Expected SleapIOError.corruptData, got \(error)")
                return
            }
        }
    }

    // MARK: - Identity (P04)

    func testRepeatedVideoRefsShareIdentity() throws {
        // P04: Same video string produces the same Video object.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,1.0,2.0,true
        vid.mp4,1,fly,0,head,3.0,4.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels[0].video === labels[1].video,
                       "Frames with the same video string must share one Video object")
    }

    func testRepeatedSkeletonRefsShareIdentity() throws {
        // P04: Same skeleton string produces the same Skeleton object.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,1.0,2.0,true
        vid.mp4,0,fly,1,head,3.0,4.0,true
        vid.mp4,1,fly,0,head,5.0,6.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertEqual(labels.skeletons.count, 1)
        let skel0 = labels[0].instances[0].skeleton
        let skel1 = labels[0].instances[1].skeleton
        let skel2 = labels[1].instances[0].skeleton
        XCTAssertTrue(skel0 === skel1, "Instances with same skeleton string must share identity")
        XCTAssertTrue(skel0 === skel2, "Instances across frames with same skeleton string must share identity")
    }

    // MARK: - Eager (P02)

    func testImportIsEager() throws {
        // P02: Labels.isLazy == false for CSV imports.
        let csv = """
        \(minHeader)
        vid.mp4,0,fly,0,head,1.0,2.0,true
        """
        let path = writeTempCSV(csv)
        let labels = try CSVCodec.read(from: path)

        XCTAssertFalse(labels.isLazy, "CSV imports must be eager (isLazy == false)")
    }
}

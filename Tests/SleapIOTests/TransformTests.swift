import XCTest
import CoreGraphics
@testable import SleapIO

/// Comprehensive tests for geometric transforms (Phase 2, Step 2.3).
///
/// Tests cover:
/// - AffineTransform matrix builder (identity, translation, scale, rotation, composition)
/// - PointsArray.apply(transform:) in-place mutation
/// - PredictedPointsArray transform preservation of scores
/// - Instance transform methods (translated, scaled, rotated, cropped, transformed)
/// - Numerical accuracy (round-trip, composition equivalence)
/// - Performance on large point arrays
final class TransformTests: XCTestCase {

    // MARK: - Helpers

    /// Float tolerance for comparisons (Float32 precision).
    private let eps: Float = 1e-5

    /// 3x3 identity matrix in row-major order.
    private let identityMatrix: [Float] = [
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    ]

    /// Build a simple skeleton with the given number of nodes.
    private func makeSkeleton(nodeCount: Int) -> Skeleton {
        let nodes = (0..<nodeCount).map { Node(name: "n\($0)") }
        return Skeleton(name: "test", nodes: nodes)
    }

    /// Build a PointsArray with given xy pairs, all visible and complete.
    private func makePoints(_ xys: [(Float, Float)]) -> PointsArray {
        let points = xys.map { Point(x: $0.0, y: $0.1, visible: true, complete: true) }
        return PointsArray(points: points)
    }

    /// Build an Instance with the given xy pairs.
    private func makeInstance(_ xys: [(Float, Float)], track: Track? = nil) -> Instance {
        let skel = makeSkeleton(nodeCount: xys.count)
        let points = xys.map { Point(x: $0.0, y: $0.1, visible: true, complete: true) }
        let pa = PointsArray(points: points)
        return Instance(skeleton: skel, points: pa, track: track)
    }

    /// Assert two Float arrays are element-wise equal within tolerance.
    private func assertArrayEqual(_ a: [Float], _ b: [Float],
                                  accuracy: Float? = nil, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let tol = accuracy ?? eps
        XCTAssertEqual(a.count, b.count, "Array length mismatch \(message)", file: file, line: line)
        for i in 0..<min(a.count, b.count) {
            XCTAssertEqual(a[i], b[i], accuracy: tol,
                           "Index \(i): \(a[i]) != \(b[i]) \(message)", file: file, line: line)
        }
    }

    /// Assert two ContiguousArray<Float> are element-wise equal within tolerance.
    private func assertCoordsEqual(_ a: ContiguousArray<Float>, _ b: ContiguousArray<Float>,
                                   accuracy: Float? = nil, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        assertArrayEqual(Array(a), Array(b), accuracy: accuracy, message, file: file, line: line)
    }

    // =========================================================================
    // MARK: - AffineTransform Matrix Builder Tests
    // =========================================================================

    func testAffineTransform_identity() {
        let m = AffineTransform2D.identity
        assertArrayEqual(m, identityMatrix, "Identity matrix")
    }

    func testAffineTransform_translation() {
        let m = AffineTransform2D.translation(dx: 10, dy: 20)
        // Row-major 3x3: [1, 0, tx, 0, 1, ty, 0, 0, 1]
        let expected: [Float] = [
            1, 0, 10,
            0, 1, 20,
            0, 0, 1,
        ]
        assertArrayEqual(m, expected, "Translation matrix")
    }

    func testAffineTransform_scale() {
        let m = AffineTransform2D.scale(sx: 2, sy: 3)
        let expected: [Float] = [
            2, 0, 0,
            0, 3, 0,
            0, 0, 1,
        ]
        assertArrayEqual(m, expected, "Scale matrix")
    }

    func testAffineTransform_scaleWithOrigin() {
        // Scale by (2, 3) around origin (5, 10):
        // translate(-5,-10), scale(2,3), translate(5,10)
        // Result: [sx, 0, ox*(1-sx), 0, sy, oy*(1-sy), 0, 0, 1]
        let m = AffineTransform2D.scale(sx: 2, sy: 3, origin: SIMD2<Float>(5, 10))
        let expected: [Float] = [
            2, 0, 5 * (1 - 2),   // = -5
            0, 3, 10 * (1 - 3),  // = -20
            0, 0, 1,
        ]
        assertArrayEqual(m, expected, "Scale with origin matrix")
    }

    func testAffineTransform_rotation90() {
        // 90 degrees CCW: cos=0, sin=1 => [0, -1, 0, 1, 0, 0, 0, 0, 1]
        let m = AffineTransform2D.rotation(radians: .pi / 2)
        let expected: [Float] = [
            0, -1, 0,
            1,  0, 0,
            0,  0, 1,
        ]
        assertArrayEqual(m, expected, "90 degree rotation matrix")
    }

    func testAffineTransform_rotationAroundOrigin() {
        // 90 degrees CCW around (5, 5):
        // translate(-5,-5), rotate(90), translate(5,5)
        let angle: Float = .pi / 2
        let cx: Float = 5
        let cy: Float = 5
        let m = AffineTransform2D.rotation(radians: angle, around: SIMD2<Float>(cx, cy))

        // Apply to point (10, 5) -- 5 units right of center
        // Should map to (5, 10) -- 5 units below center
        let x: Float = 10, y: Float = 5
        let nx = m[0] * x + m[1] * y + m[2]
        let ny = m[3] * x + m[4] * y + m[5]
        XCTAssertEqual(nx, 5, accuracy: eps, "Rotated x")
        XCTAssertEqual(ny, 10, accuracy: eps, "Rotated y")
    }

    func testAffineTransform_composeTranslationThenScale() {
        // First translate by (10, 20), then scale by (2, 3)
        // compose(scale, translate) since matrix multiplication is right-to-left
        // Result: scale * translate = [2,0,20, 0,3,60, 0,0,1]
        let t = AffineTransform2D.translation(dx: 10, dy: 20)
        let s = AffineTransform2D.scale(sx: 2, sy: 3)
        let m = AffineTransform2D.compose(s, t)
        let expected: [Float] = [
            2, 0, 20,
            0, 3, 60,
            0, 0, 1,
        ]
        assertArrayEqual(m, expected, "Compose translate then scale")
    }

    func testAffineTransform_composeWithIdentityIsNoop() {
        let t = AffineTransform2D.translation(dx: 7, dy: -3)
        let m1 = AffineTransform2D.compose(AffineTransform2D.identity, t)
        let m2 = AffineTransform2D.compose(t, AffineTransform2D.identity)
        assertArrayEqual(m1, t, "identity * t == t")
        assertArrayEqual(m2, t, "t * identity == t")
    }

    // =========================================================================
    // MARK: - PointsArray.apply(transform:) Tests
    // =========================================================================

    func testPointsArray_applyIdentity() {
        var pa = makePoints([(1, 2), (3, 4), (5, 6)])
        let original = pa.coordinates
        pa.apply(transform: AffineTransform2D.identity)
        assertCoordsEqual(pa.coordinates, original, "Identity leaves coordinates unchanged")
    }

    func testPointsArray_applyTranslation() {
        var pa = makePoints([(1, 2), (3, 4)])
        pa.apply(transform: AffineTransform2D.translation(dx: 10, dy: 20))
        let expected = ContiguousArray<Float>([11, 22, 13, 24])
        assertCoordsEqual(pa.coordinates, expected, "Translation shifts all points")
    }

    func testPointsArray_applyScale() {
        var pa = makePoints([(2, 3), (4, 5)])
        pa.apply(transform: AffineTransform2D.scale(sx: 2, sy: 3))
        let expected = ContiguousArray<Float>([4, 9, 8, 15])
        assertCoordsEqual(pa.coordinates, expected, "Scale multiplies coordinates")
    }

    func testPointsArray_applyRotation90() {
        // (1, 0) rotated 90 CCW => (0, 1)
        var pa = makePoints([(1, 0)])
        pa.apply(transform: AffineTransform2D.rotation(radians: .pi / 2))
        XCTAssertEqual(pa.coordinates[0], 0, accuracy: eps, "x after 90 rotation")
        XCTAssertEqual(pa.coordinates[1], 1, accuracy: eps, "y after 90 rotation")
    }

    func testPointsArray_applyRotation180() {
        // (1, 0) rotated 180 => (-1, 0)
        var pa = makePoints([(1, 0)])
        pa.apply(transform: AffineTransform2D.rotation(radians: .pi))
        XCTAssertEqual(pa.coordinates[0], -1, accuracy: eps, "x after 180 rotation")
        XCTAssertEqual(pa.coordinates[1], 0, accuracy: eps, "y after 180 rotation")
    }

    func testPointsArray_applyEmpty() {
        var pa = makePoints([])
        let original = pa.coordinates
        pa.apply(transform: AffineTransform2D.translation(dx: 10, dy: 20))
        assertCoordsEqual(pa.coordinates, original, "Empty PointsArray is no-op")
        XCTAssertEqual(pa.count, 0)
    }

    func testPointsArray_applyPreservesVisibility() {
        var pa = PointsArray(points: [
            Point(x: 1, y: 2, visible: true, complete: false),
            Point(x: 3, y: 4, visible: false, complete: true),
            Point(x: 5, y: 6, visible: true, complete: true),
        ])
        pa.apply(transform: AffineTransform2D.translation(dx: 10, dy: 20))
        XCTAssertEqual(pa.visibility[0], true)
        XCTAssertEqual(pa.visibility[1], false)
        XCTAssertEqual(pa.visibility[2], true)
    }

    func testPointsArray_applyPreservesCompleteness() {
        var pa = PointsArray(points: [
            Point(x: 1, y: 2, visible: true, complete: false),
            Point(x: 3, y: 4, visible: false, complete: true),
            Point(x: 5, y: 6, visible: true, complete: true),
        ])
        pa.apply(transform: AffineTransform2D.scale(sx: 2, sy: 2))
        XCTAssertEqual(pa.completeness[0], false)
        XCTAssertEqual(pa.completeness[1], true)
        XCTAssertEqual(pa.completeness[2], true)
    }

    // =========================================================================
    // MARK: - PredictedPointsArray Transform Tests
    // =========================================================================

    func testPredictedPointsArray_transformPreservesScores() {
        var ppa = PredictedPointsArray(points: [
            PredictedPoint(x: 1, y: 2, score: 0.9),
            PredictedPoint(x: 3, y: 4, score: 0.8),
            PredictedPoint(x: 5, y: 6, score: 0.7),
        ])
        ppa.points.apply(transform: AffineTransform2D.translation(dx: 10, dy: 20))
        XCTAssertEqual(ppa.scores[0], 0.9, accuracy: eps, "Score 0 preserved")
        XCTAssertEqual(ppa.scores[1], 0.8, accuracy: eps, "Score 1 preserved")
        XCTAssertEqual(ppa.scores[2], 0.7, accuracy: eps, "Score 2 preserved")
    }

    func testPredictedPointsArray_transformDelegatesToPointsArray() {
        var ppa = PredictedPointsArray(points: [
            PredictedPoint(x: 1, y: 2, score: 0.9),
            PredictedPoint(x: 3, y: 4, score: 0.8),
        ])
        ppa.points.apply(transform: AffineTransform2D.translation(dx: 10, dy: 20))
        XCTAssertEqual(ppa.points.coordinates[0], 11, accuracy: eps)
        XCTAssertEqual(ppa.points.coordinates[1], 22, accuracy: eps)
        XCTAssertEqual(ppa.points.coordinates[2], 13, accuracy: eps)
        XCTAssertEqual(ppa.points.coordinates[3], 24, accuracy: eps)
    }

    // =========================================================================
    // MARK: - Instance Transform Tests
    // =========================================================================

    func testInstance_translatedByShiftsAllPoints() {
        let inst = makeInstance([(1, 2), (3, 4), (5, 6)])
        let result = inst.translated(by: SIMD2<Float>(10, 20))
        XCTAssertEqual(result.points[0].x, 11, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 22, accuracy: eps)
        XCTAssertEqual(result.points[1].x, 13, accuracy: eps)
        XCTAssertEqual(result.points[1].y, 24, accuracy: eps)
        XCTAssertEqual(result.points[2].x, 15, accuracy: eps)
        XCTAssertEqual(result.points[2].y, 26, accuracy: eps)
    }

    func testInstance_scaledByOrigin() {
        // Scale by (2, 3) relative to origin (1, 2)
        let inst = makeInstance([(1, 2), (3, 4)])
        let result = inst.scaled(by: SIMD2<Float>(2, 3), origin: SIMD2<Float>(1, 2))
        // (1,2) relative to (1,2) is (0,0) => scaled (0,0) => (1,2)
        XCTAssertEqual(result.points[0].x, 1, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 2, accuracy: eps)
        // (3,4) relative to (1,2) is (2,2) => scaled (4,6) => (5,8)
        XCTAssertEqual(result.points[1].x, 5, accuracy: eps)
        XCTAssertEqual(result.points[1].y, 8, accuracy: eps)
    }

    func testInstance_rotatedByAround() {
        // Rotate (10, 5) by 90 degrees CCW around (5, 5)
        let inst = makeInstance([(10, 5)])
        let result = inst.rotated(by: .pi / 2, around: SIMD2<Float>(5, 5))
        XCTAssertEqual(result.points[0].x, 5, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 10, accuracy: eps)
    }

    func testInstance_croppedMarksOutOfBoundsInvisible() {
        // Points at (5, 5), (15, 15), (25, 25) with crop rect (0, 0, 20, 20)
        let inst = makeInstance([(5, 5), (15, 15), (25, 25)])
        let result = inst.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        // (5,5) and (15,15) are inside, (25,25) is outside
        XCTAssertTrue(result.points.visibility[0], "Point inside crop rect should be visible")
        XCTAssertTrue(result.points.visibility[1], "Point inside crop rect should be visible")
        XCTAssertFalse(result.points.visibility[2], "Point outside crop rect should be invisible")
    }

    func testInstance_croppedPreservesInBoundsVisibility() {
        // Point that was already invisible should stay invisible after crop
        let skel = makeSkeleton(nodeCount: 2)
        let pa = PointsArray(points: [
            Point(x: 5, y: 5, visible: false, complete: true),   // inside but already invisible
            Point(x: 10, y: 10, visible: true, complete: true),  // inside and visible
        ])
        let inst = Instance(skeleton: skel, points: pa)
        let result = inst.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        // The already-invisible point should remain invisible
        XCTAssertFalse(result.points.visibility[0], "Already-invisible point stays invisible")
        XCTAssertTrue(result.points.visibility[1], "Visible in-bounds point stays visible")
    }

    func testInstance_transformedByArbitraryMatrix() {
        // Apply a combined translate+scale matrix directly
        let matrix: [Float] = [
            2, 0, 10,
            0, 3, 20,
            0, 0, 1,
        ]
        let inst = makeInstance([(1, 2), (3, 4)])
        let result = inst.transformed(by: matrix)
        // x' = 2*x + 10, y' = 3*y + 20
        XCTAssertEqual(result.points[0].x, 12, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 26, accuracy: eps)
        XCTAssertEqual(result.points[1].x, 16, accuracy: eps)
        XCTAssertEqual(result.points[1].y, 32, accuracy: eps)
    }

    func testInstance_transformedReturnsNewInstance() {
        let inst = makeInstance([(1, 2)])
        let result = inst.transformed(by: AffineTransform2D.identity)
        XCTAssertFalse(inst === result, "transformed() must return a NEW instance (different identity)")
    }

    func testInstance_transformedPreservesSkeletonReference() {
        let inst = makeInstance([(1, 2)])
        let result = inst.translated(by: SIMD2<Float>(10, 20))
        XCTAssertTrue(inst.skeleton === result.skeleton,
                      "Transformed instance should share the same skeleton reference")
    }

    func testInstance_transformedPreservesTrackReference() {
        let track = Track(name: "animal1")
        let inst = makeInstance([(1, 2), (3, 4)], track: track)
        let result = inst.translated(by: SIMD2<Float>(10, 20))
        XCTAssertTrue(result.track === track,
                      "Transformed instance should preserve the track reference")
    }

    // =========================================================================
    // MARK: - PredictedInstance Transform Tests
    // =========================================================================

    /// Build a PredictedInstance with given xy pairs and per-point scores.
    private func makePredictedInstance(
        _ xys: [(Float, Float)],
        pointScores: [Float],
        instanceScore: Float = 0.95,
        track: Track? = nil,
        fromPredicted: PredictedInstance? = nil
    ) -> PredictedInstance {
        let skel = makeSkeleton(nodeCount: xys.count)
        let predPoints = xys.enumerated().map { (i, xy) in
            PredictedPoint(x: xy.0, y: xy.1, visible: true, complete: true, score: pointScores[i])
        }
        let ppa = PredictedPointsArray(points: predPoints)
        let inst = PredictedInstance(skeleton: skel, points: ppa, score: instanceScore, track: track)
        inst.fromPredicted = fromPredicted
        return inst
    }

    func testPredictedInstance_translatedPreservesScore() {
        let pred = makePredictedInstance(
            [(1, 2), (3, 4)],
            pointScores: [0.9, 0.8],
            instanceScore: 0.95
        )
        let result = pred.translated(by: SIMD2<Float>(10, 20))

        // Must return a PredictedInstance
        guard let predResult = result as? PredictedInstance else {
            XCTFail("translated() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertEqual(predResult.score, 0.95, accuracy: eps, "Instance score preserved")
    }

    func testPredictedInstance_translatedPreservesPerPointScores() {
        let pred = makePredictedInstance(
            [(1, 2), (3, 4)],
            pointScores: [0.9, 0.8],
            instanceScore: 0.95
        )
        let result = pred.translated(by: SIMD2<Float>(10, 20))

        guard let predResult = result as? PredictedInstance else {
            XCTFail("translated() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertEqual(predResult.predictedPoints.scores[0], 0.9, accuracy: eps, "Point score 0 preserved")
        XCTAssertEqual(predResult.predictedPoints.scores[1], 0.8, accuracy: eps, "Point score 1 preserved")
    }

    func testPredictedInstance_translatedCoordinatesAreCorrect() {
        let pred = makePredictedInstance(
            [(1, 2), (3, 4)],
            pointScores: [0.9, 0.8]
        )
        let result = pred.translated(by: SIMD2<Float>(10, 20))

        XCTAssertEqual(result.points[0].x, 11, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 22, accuracy: eps)
        XCTAssertEqual(result.points[1].x, 13, accuracy: eps)
        XCTAssertEqual(result.points[1].y, 24, accuracy: eps)
    }

    func testPredictedInstance_scaledPreservesType() {
        let pred = makePredictedInstance(
            [(2, 3)],
            pointScores: [0.85],
            instanceScore: 0.9
        )
        let result = pred.scaled(by: SIMD2<Float>(2, 3))

        guard let predResult = result as? PredictedInstance else {
            XCTFail("scaled() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertEqual(predResult.score, 0.9, accuracy: eps)
        XCTAssertEqual(predResult.predictedPoints.scores[0], 0.85, accuracy: eps)
    }

    func testPredictedInstance_rotatedPreservesType() {
        let pred = makePredictedInstance(
            [(1, 0)],
            pointScores: [0.75],
            instanceScore: 0.88
        )
        let result = pred.rotated(by: .pi / 2)

        guard let predResult = result as? PredictedInstance else {
            XCTFail("rotated() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertEqual(predResult.score, 0.88, accuracy: eps)
        XCTAssertEqual(predResult.predictedPoints.scores[0], 0.75, accuracy: eps)
    }

    func testPredictedInstance_croppedPreservesType() {
        let pred = makePredictedInstance(
            [(5, 5), (25, 25)],
            pointScores: [0.9, 0.7],
            instanceScore: 0.85
        )
        let result = pred.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))

        guard let predResult = result as? PredictedInstance else {
            XCTFail("cropped() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertEqual(predResult.score, 0.85, accuracy: eps)
        XCTAssertEqual(predResult.predictedPoints.scores[0], 0.9, accuracy: eps)
        XCTAssertEqual(predResult.predictedPoints.scores[1], 0.7, accuracy: eps)
        // Visibility: (5,5) is inside, (25,25) is outside
        XCTAssertTrue(predResult.points.visibility[0])
        XCTAssertFalse(predResult.points.visibility[1])
    }

    func testPredictedInstance_transformedPreservesFromPredicted() {
        // Create a "source" predicted instance
        let source = makePredictedInstance(
            [(10, 20)],
            pointScores: [0.99],
            instanceScore: 0.98
        )
        // Create a user instance that references it
        let skel = makeSkeleton(nodeCount: 1)
        let userInst = Instance(
            skeleton: skel,
            points: PointsArray(points: [Point(x: 10, y: 20)]),
            fromPredicted: source
        )
        let result = userInst.translated(by: SIMD2<Float>(5, 5))
        XCTAssertTrue(result.fromPredicted === source,
                      "fromPredicted reference must be preserved through transforms")
    }

    func testPredictedInstance_transformedPreservesFromPredictedOnPredicted() {
        let source = makePredictedInstance(
            [(10, 20)],
            pointScores: [0.99],
            instanceScore: 0.98
        )
        let pred = makePredictedInstance(
            [(1, 2)],
            pointScores: [0.9],
            instanceScore: 0.85,
            fromPredicted: source
        )
        let result = pred.translated(by: SIMD2<Float>(5, 5))

        guard let predResult = result as? PredictedInstance else {
            XCTFail("translated() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertTrue(predResult.fromPredicted === source,
                      "fromPredicted reference must be preserved on PredictedInstance transforms")
    }

    func testPredictedInstance_transformedPreservesTrack() {
        let track = Track(name: "animal1")
        let pred = makePredictedInstance(
            [(1, 2)],
            pointScores: [0.9],
            instanceScore: 0.85,
            track: track
        )
        let result = pred.translated(by: SIMD2<Float>(10, 20))

        guard let predResult = result as? PredictedInstance else {
            XCTFail("translated() on PredictedInstance must return PredictedInstance")
            return
        }
        XCTAssertTrue(predResult.track === track,
                      "Track reference must be preserved on PredictedInstance transforms")
    }

    // =========================================================================
    // MARK: - Numerical Accuracy Tests
    // =========================================================================

    func testNumerical_doubleRotation180MatchesSingle180() {
        // Rotate 90 twice vs rotate 180 once
        var pa1 = makePoints([(3, 7), (10, -5)])
        var pa2 = pa1  // value copy

        // Single 180 rotation
        pa1.apply(transform: AffineTransform2D.rotation(radians: .pi))

        // Two 90 rotations
        pa2.apply(transform: AffineTransform2D.rotation(radians: .pi / 2))
        pa2.apply(transform: AffineTransform2D.rotation(radians: .pi / 2))

        assertCoordsEqual(pa1.coordinates, pa2.coordinates, accuracy: 1e-4,
                          "Double 90 rotation should match single 180 rotation")
    }

    func testNumerical_scaleThenInverseScaleRoundTrips() {
        let original = makePoints([(3.7, -2.1), (100.5, 0.001)])
        var pa = original

        pa.apply(transform: AffineTransform2D.scale(sx: 2.5, sy: 0.4))
        pa.apply(transform: AffineTransform2D.scale(sx: 1.0 / 2.5, sy: 1.0 / 0.4))

        assertCoordsEqual(pa.coordinates, original.coordinates, accuracy: 1e-4,
                          "Scale then inverse scale should return to original")
    }

    func testNumerical_translateThenInverseTranslateRoundTrips() {
        let original = makePoints([(3.7, -2.1), (100.5, 0.001)])
        var pa = original

        pa.apply(transform: AffineTransform2D.translation(dx: 42.5, dy: -17.3))
        pa.apply(transform: AffineTransform2D.translation(dx: -42.5, dy: 17.3))

        assertCoordsEqual(pa.coordinates, original.coordinates, accuracy: eps,
                          "Translate then inverse translate should return to original")
    }

    func testNumerical_composeMatchesSequentialApply() {
        // Applying composed matrix should give same result as applying sequentially
        let original = makePoints([(3, 7), (10, -5), (0, 0)])

        // Sequential apply
        var pa1 = original
        pa1.apply(transform: AffineTransform2D.translation(dx: 5, dy: -3))
        pa1.apply(transform: AffineTransform2D.scale(sx: 2, sy: 0.5))
        pa1.apply(transform: AffineTransform2D.rotation(radians: .pi / 4))

        // Composed matrix (applied right to left: translate, then scale, then rotate)
        var pa2 = original
        let composed = AffineTransform2D.compose(
            AffineTransform2D.rotation(radians: .pi / 4),
            AffineTransform2D.compose(
                AffineTransform2D.scale(sx: 2, sy: 0.5),
                AffineTransform2D.translation(dx: 5, dy: -3)
            )
        )
        pa2.apply(transform: composed)

        assertCoordsEqual(pa1.coordinates, pa2.coordinates, accuracy: 1e-4,
                          "Composed matrix should match sequential application")
    }

    // =========================================================================
    // MARK: - Edge Cases
    // =========================================================================

    func testInstance_scaledByDefaultOriginIsZero() {
        // Calling scaled without origin should use .zero
        let inst = makeInstance([(2, 3)])
        let result = inst.scaled(by: SIMD2<Float>(2, 3))
        XCTAssertEqual(result.points[0].x, 4, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 9, accuracy: eps)
    }

    func testInstance_rotatedDefaultOriginIsZero() {
        // Calling rotated without origin should rotate around .zero
        let inst = makeInstance([(1, 0)])
        let result = inst.rotated(by: .pi / 2)
        XCTAssertEqual(result.points[0].x, 0, accuracy: eps)
        XCTAssertEqual(result.points[0].y, 1, accuracy: eps)
    }

    func testInstance_croppedOnBoundaryIsInside() {
        // A point exactly on the crop boundary should be considered inside
        let inst = makeInstance([(0, 0), (20, 20)])
        let result = inst.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertTrue(result.points.visibility[0], "Point at origin of crop rect is inside")
        XCTAssertTrue(result.points.visibility[1], "Point at corner of crop rect is inside")
    }

    func testPointsArray_applyWithNaNCoordinates() {
        // NaN coordinates (uninitialized points) should remain NaN after transform
        var pa = PointsArray(count: 2)  // all NaN by default
        pa.apply(transform: AffineTransform2D.translation(dx: 10, dy: 20))
        XCTAssertTrue(pa.coordinates[0].isNaN, "NaN x should stay NaN after transform")
        XCTAssertTrue(pa.coordinates[1].isNaN, "NaN y should stay NaN after transform")
    }

    // =========================================================================
    // MARK: - Performance Tests
    // =========================================================================

    func testPerformance_largePointsArrayTransform() {
        // 100k points => 200k floats
        let n = 100_000
        var coords = ContiguousArray<Float>(repeating: 0, count: n * 2)
        for i in 0..<(n * 2) {
            coords[i] = Float(i)
        }
        var pa = PointsArray(
            coordinates: coords,
            visibility: ContiguousArray(repeating: true, count: n),
            completeness: ContiguousArray(repeating: true, count: n)
        )

        let matrix = AffineTransform2D.compose(
            AffineTransform2D.rotation(radians: .pi / 6),
            AffineTransform2D.compose(
                AffineTransform2D.scale(sx: 1.5, sy: 2.0),
                AffineTransform2D.translation(dx: 100, dy: -50)
            )
        )

        measure {
            pa.apply(transform: matrix)
        }
    }
}

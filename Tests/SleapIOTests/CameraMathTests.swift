import XCTest
@testable import SleapIO

/// Issue #57: Camera math — Rodrigues transform, extrinsic compose/decompose,
/// shape validation, and the `CameraGroup` container.
final class CameraMathTests: XCTestCase {

    // MARK: - Helpers

    /// Assert two equal-length float arrays match componentwise.
    private func assertArraysEqual(
        _ a: [Float], _ b: [Float], accuracy: Float = 1e-4,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.count, b.count, "count mismatch \(message)", file: file, line: line)
        for i in 0..<min(a.count, b.count) {
            XCTAssertEqual(
                a[i], b[i], accuracy: accuracy,
                "index \(i) \(message)", file: file, line: line
            )
        }
    }

    /// Assert `error` is a `CameraError.invalidShape`.
    private func assertInvalidShape(
        _ error: Error, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case CameraError.invalidShape = error else {
            XCTFail("expected CameraError.invalidShape, got \(error)", file: file, line: line)
            return
        }
    }

    /// Row-major 3x3 matrix product `a · b`.
    private func matMul3(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var s: Float = 0
                for k in 0..<3 { s += a[r * 3 + k] * b[k * 3 + c] }
                out[r * 3 + c] = s
            }
        }
        return out
    }

    // MARK: - Forward Rodrigues sanity

    func testForwardRodriguesIdentityForZeroVector() throws {
        let r = try Camera.rotationMatrix(fromRotationVector: [0, 0, 0])
        assertArraysEqual(r, [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    func testForwardRodriguesProducesOrthonormalMatrix() throws {
        // Arbitrary rotation; RᵀR should be identity and det ≈ 1.
        let r = try Camera.rotationMatrix(fromRotationVector: [0.3, -0.7, 1.1])
        let rt = [r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]]  // transpose
        let product = matMul3(rt, r)
        assertArraysEqual(product, [1, 0, 0, 0, 1, 0, 0, 0, 1], accuracy: 1e-5)

        let det = r[0] * (r[4] * r[8] - r[5] * r[7])
            - r[1] * (r[3] * r[8] - r[5] * r[6])
            + r[2] * (r[3] * r[7] - r[4] * r[6])
        XCTAssertEqual(det, 1, accuracy: 1e-5)
    }

    func testForwardRodriguesRejectsWrongShape() {
        XCTAssertThrowsError(try Camera.rotationMatrix(fromRotationVector: [1, 2])) {
            assertInvalidShape($0)
        }
        XCTAssertThrowsError(try Camera.rotationMatrix(fromRotationVector: [1, 2, 3, 4])) {
            assertInvalidShape($0)
        }
    }

    func testInverseRodriguesRejectsWrongShape() {
        XCTAssertThrowsError(try Camera.rotationVector(fromRotationMatrix: [1, 0, 0, 0])) {
            assertInvalidShape($0)
        }
    }

    // MARK: - Rodrigues round-trip (rvec -> matrix -> rvec)

    func testRodriguesRoundTripSeveralRotations() throws {
        // Angles in (0, π) about various axes — the vector is uniquely recovered.
        let cases: [[Float]] = [
            [0, 0, 0],                 // identity
            [0.01, 0, 0],              // near-zero
            [0, 0.02, -0.015],         // near-zero, mixed axes
            [0.1, 0.2, 0.3],           // small general
            [0, 0, Float.pi / 2],      // 90° about z
            [1.0, -0.5, 0.75],         // general
            [2.0, 0, 0],              // ~114.6° about x
        ]
        for rvec in cases {
            let matrix = try Camera.rotationMatrix(fromRotationVector: rvec)
            let recovered = try Camera.rotationVector(fromRotationMatrix: matrix)
            assertArraysEqual(recovered, rvec, "rvec=\(rvec)")
        }
    }

    func testRodriguesRoundTripAxisAlignedPi() throws {
        for rvec in [[Float.pi, 0, 0], [0, Float.pi, 0], [0, 0, Float.pi]] {
            let matrix = try Camera.rotationMatrix(fromRotationVector: rvec)
            let recovered = try Camera.rotationVector(fromRotationMatrix: matrix)
            assertArraysEqual(recovered, rvec, "rvec=\(rvec)")
        }
    }

    func testRodriguesRoundTripGeneralPi() throws {
        // π rotation about (1,1,1)/√3.
        let axis: Float = 1.0 / Float(3.0.squareRoot())
        let rvec = [Float.pi * axis, Float.pi * axis, Float.pi * axis]
        let matrix = try Camera.rotationMatrix(fromRotationVector: rvec)
        let recovered = try Camera.rotationVector(fromRotationMatrix: matrix)
        assertArraysEqual(recovered, rvec, accuracy: 1e-3, "general π")
    }

    func testInverseRodriguesRoundTripThroughMatrix() throws {
        // matrix -> rvec -> matrix should recover the matrix even near π,
        // where the axis-angle sign is ambiguous.
        let original = try Camera.rotationMatrix(fromRotationVector: [0.9, -1.2, 0.4])
        let rvec = try Camera.rotationVector(fromRotationMatrix: original)
        let rebuilt = try Camera.rotationMatrix(fromRotationVector: rvec)
        assertArraysEqual(rebuilt, original, accuracy: 1e-4)
    }

    // MARK: - Extrinsic matrix compose

    func testExtrinsicMatrixIsNilWhenUnset() {
        XCTAssertNil(Camera(name: "cam").extrinsicMatrix)
        // rvec set but tvec unset -> still nil.
        let cam = Camera(name: "cam", rvec: [0, 0, 0])
        XCTAssertNil(cam.extrinsicMatrix)
    }

    func testExtrinsicMatrixCompose() throws {
        let rvec: [Float] = [0.1, 0.2, 0.3]
        let tvec: [Float] = [1, 2, 3]
        let cam = Camera(name: "cam", rvec: rvec, tvec: tvec)

        let em = try XCTUnwrap(cam.extrinsicMatrix)
        XCTAssertEqual(em.count, 16)

        // Rotation block matches the forward Rodrigues matrix.
        let rot = try Camera.rotationMatrix(fromRotationVector: rvec)
        let emRot = [em[0], em[1], em[2], em[4], em[5], em[6], em[8], em[9], em[10]]
        assertArraysEqual(emRot, rot)

        // Translation column and homogeneous bottom row.
        assertArraysEqual([em[3], em[7], em[11]], tvec)
        assertArraysEqual([em[12], em[13], em[14], em[15]], [0, 0, 0, 1])
    }

    // MARK: - Extrinsic matrix decompose (set) round-trip

    func testExtrinsicMatrixDecomposeRoundTrip() throws {
        let rvec: [Float] = [0.4, -0.25, 0.6]
        let tvec: [Float] = [-5, 10, 2.5]
        let source = Camera(name: "src", rvec: rvec, tvec: tvec)
        let em = try XCTUnwrap(source.extrinsicMatrix)

        let dest = Camera(name: "dst")
        dest.extrinsicMatrix = em

        assertArraysEqual(try XCTUnwrap(dest.rvec), rvec)
        assertArraysEqual(try XCTUnwrap(dest.tvec), tvec)
        // Recomposing yields the same matrix.
        assertArraysEqual(try XCTUnwrap(dest.extrinsicMatrix), em)
    }

    func testSettingExtrinsicMatrixNilClearsVectors() {
        let cam = Camera(name: "cam", rvec: [0.1, 0.2, 0.3], tvec: [1, 2, 3])
        cam.extrinsicMatrix = nil
        XCTAssertNil(cam.rvec)
        XCTAssertNil(cam.tvec)
    }

    func testSetExtrinsicMatrixRejectsWrongShape() {
        let cam = Camera(name: "cam")
        XCTAssertThrowsError(try cam.setExtrinsicMatrix([Float](repeating: 0, count: 12))) {
            assertInvalidShape($0)
        }
    }

    // MARK: - Shape validation

    func testSetRotationVectorValidation() throws {
        let cam = Camera(name: "cam")
        XCTAssertThrowsError(try cam.setRotationVector([1, 2])) { assertInvalidShape($0) }
        XCTAssertThrowsError(try cam.setRotationVector([1, 2, 3, 4])) { assertInvalidShape($0) }

        try cam.setRotationVector([1, 2, 3])
        assertArraysEqual(try XCTUnwrap(cam.rvec), [1, 2, 3])

        try cam.setRotationVector(nil)
        XCTAssertNil(cam.rvec)
    }

    func testSetTranslationVectorValidation() throws {
        let cam = Camera(name: "cam")
        XCTAssertThrowsError(try cam.setTranslationVector([1, 2, 3, 4])) { assertInvalidShape($0) }

        try cam.setTranslationVector([4, 5, 6])
        assertArraysEqual(try XCTUnwrap(cam.tvec), [4, 5, 6])
    }

    func testValidatePassesForWellFormedCamera() throws {
        let cam = Camera(
            name: "cam",
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            distortionCoefficients: [0, 0, 0, 0, 0],
            size: (width: 640, height: 480),
            rvec: [0, 0, 0],
            tvec: [0, 0, 0]
        )
        XCTAssertNoThrow(try cam.validate())
    }

    func testValidateThrowsForBadShapes() {
        let badRvec = Camera(name: "cam", rvec: [1, 2])
        XCTAssertThrowsError(try badRvec.validate()) { assertInvalidShape($0) }

        let badTvec = Camera(name: "cam", tvec: [1, 2, 3, 4])
        XCTAssertThrowsError(try badTvec.validate()) { assertInvalidShape($0) }

        let badMatrix = Camera(name: "cam", matrix: [1, 2, 3, 4])
        XCTAssertThrowsError(try badMatrix.validate()) { assertInvalidShape($0) }

        let badDist = Camera(name: "cam", distortionCoefficients: [0, 0])
        XCTAssertThrowsError(try badDist.validate()) { assertInvalidShape($0) }
    }

    // MARK: - CameraGroup

    func testCameraGroupDefaultsAreEmpty() {
        let group = CameraGroup()
        XCTAssertTrue(group.cameras.isEmpty)
        XCTAssertTrue(group.metadata.isEmpty)
    }

    func testCameraGroupConstructionAndAccessors() {
        let c1 = Camera(name: "left")
        let c2 = Camera(name: "right")
        let group = CameraGroup(cameras: [c1, c2], metadata: ["rig": "arena-1"])

        XCTAssertEqual(group.cameras.count, 2)
        XCTAssertTrue(group.cameras[0] === c1)
        XCTAssertTrue(group.cameras[1] === c2)
        XCTAssertEqual(group.metadata["rig"], .string("arena-1"))

        // Mutable container.
        let c3 = Camera(name: "top")
        group.cameras.append(c3)
        XCTAssertEqual(group.cameras.count, 3)
        XCTAssertTrue(group.cameras.last === c3)
    }
}
